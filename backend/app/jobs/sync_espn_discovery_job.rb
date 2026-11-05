# Daily ESPN fixture discovery for every league with a verified slug.
#
# WHY THIS EXISTS AS A SCHEDULED JOB
# ----------------------------------
# `SyncFixturesJob` refreshes the football-data.co.uk CSV, which only carries
# matches once they are played. The upcoming fixture list comes from ESPN and,
# before this job, was filled only by a person running a rake task over a set of
# dates. That is what produced a 26-day hole in the Premier League while every
# individual run reported success.
#
# WHAT IT DOES
# ------------
# For each catalogue code with a verified slug (EspnLeagueCoverage::VERIFIED) and
# an internal Season named for the current window, run
# Sync::EspnDiscoverySynchronizer over a WINDOW rather than a single date. The
# window is clipped to the season by the synchronizer itself, so a July run never
# imports next season's fixtures into this one.
#
# WHICH WINDOW
# ------------
# A rolling window around now, not the whole season: the season sweep is a
# one-off backfill (`rake espn:discover`), while the daily job only needs enough
# reach to notice a newly listed or moved fixture. `WINDOW_DAYS` is deliberately
# several weeks so a fixture added far ahead still lands.
#
# A league whose synchronizer reports a failure is counted and logged; one
# failing league must not stop the others, which is why each is independent.
# Leagues with no verified slug are skipped explicitly and named in the log, so
# "no upcoming fixtures" is always explainable.
class SyncEspnDiscoveryJob < ApplicationJob
  queue_as :sync
  sidekiq_options retry: 2

  # Days back and forward from today that each run refreshes.
  WINDOW_DAYS = 35

  def perform(trigger = 'schedule', window_days: WINDOW_DAYS)
    today = Date.current
    from_date = today - window_days
    to_date = today + window_days

    results = {}
    EspnLeagueCoverage::VERIFIED.each do |code, slug|
      season = current_season_for(code)
      if season.nil?
        results[code] = :no_season
        Rails.logger.info("[espn:discovery] #{code}: no internal season for #{today.year}; skipped")
        next
      end

      run = Sync::EspnDiscoverySynchronizer.new.call(
        league: slug, internal_season: season,
        from_date: from_date, to_date: to_date, trigger: trigger.to_s
      )
      results[code] = run.status == 'failed' ? :failed : :succeeded
      Rails.logger.info(
        "[espn:discovery] #{code} (#{slug}) #{run.status}: created=#{run.created} " \
        "updated=#{run.updated} rejected=#{run.rejected} window=#{run.details['from']}..#{run.details['to']}"
      )
    end

    EspnLeagueCoverage.unimportable_scope.each do |code|
      Rails.logger.info(
        "[espn:discovery] #{code}: no verified ESPN fixture feed — " \
        "#{EspnLeagueCoverage.unavailable_reason(code)}"
      )
      results[code] = :no_feed
    end

    # Every remaining catalogue code is named too. A code that simply does not
    # appear in the report is indistinguishable from one nobody thought about,
    # which is the failure mode this job exists to remove.
    # Every remaining catalogue code is named too. A code that simply does not
    # appear in the report is indistinguishable from one nobody thought about,
    # which is the failure mode this job exists to remove.
    #
    # `:no_feed` is reserved for leagues the PRODUCT expects (PRODUCT_SCOPE) but
    # which no provider can serve — a gap somebody must fix. A league outside the
    # product scope (`:out_of_scope`) is a deliberate exclusion, not a gap.
    (CompetitionCatalogue::ENTRIES.keys - results.keys).each do |code|
      reason = EspnLeagueCoverage.unavailable_reason(code)
      in_scope = EspnLeagueCoverage::PRODUCT_SCOPE.include?(code)
      status = in_scope ? :no_feed : :out_of_scope
      Rails.logger.info("[espn:discovery] #{code}: not imported — #{reason || 'not in the product scope'}")
      results[code] = status
    end

    raise "espn discovery failed for #{results.select { |_k, v| v == :failed }.keys.join(', ')}" \
      if results.value?(:failed)

    results
  rescue Sync::SyncRun::AlreadyRunning => e
    Rails.logger.info("[espn:discovery] skipped, already running: #{e.message}")
    nil
  end

  private

  def current_season_for(code)
    Sync::EspnLeagueSeason.find(code, Sync::SeasonWindow.current_label)
  end
end
