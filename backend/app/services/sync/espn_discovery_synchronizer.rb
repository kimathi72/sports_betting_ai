module Sync
  # Raised when a discovery window cannot be attributed to a season.
  class SeasonWindowError < ArgumentError; end

  # Fixture discovery for one ESPN league across a date window.
  #
  # WHY THIS EXISTS
  # ---------------
  # `EspnSynchronizer` fetches ONE scoreboard request. That is the right unit for
  # a live poll, but it is the wrong unit for filling a season: the 2026-10-30
  # backfill called it once per date an operator happened to type, so the Premier
  # League ended up with 80 completed matches to 25 October and a hole from
  # 26 October to 20 November while ESPN was serving those fixtures. Every
  # individual run succeeded and the ledger showed 58 green entries — a coverage
  # gap that no per-run status could express.
  #
  # So discovery is explicit about the window: it walks every day in it, and it
  # records how many days it searched and which of them had events. An empty day
  # (the league did not play) and a missing day (nobody asked) are now different
  # facts in the ledger instead of the same silence.
  #
  # REUSES THE EXISTING WRITE PATH
  # ------------------------------
  # Each event goes through `Import::EspnAdapter` and `Import::ApiFootballReconciler`
  # exactly as the single-date path does, so duplicate prevention, reschedule
  # handling, the completed-result precedence rule and provider-identity recording
  # are not re-implemented here. This class only decides WHICH days to ask about
  # and which season the answers belong to.
  #
  # SEASON BOUNDARY
  # ---------------
  # Every window is clipped to the season it is importing. The live database has
  # the defect this prevents: season "2025/26" holds one scheduled fixture dated
  # 2026-12-26 because a date range was imported with no boundary at all.
  class EspnDiscoverySynchronizer
    KIND = Sync::SyncRun::FIXTURE_KIND
    PROVIDER = Import::EspnAdapter::PROVIDER

    def initialize(client: Import::EspnClient.new,
                   adapter: Import::EspnAdapter.new,
                   reconciler: Import::ApiFootballReconciler.new)
      @client = client
      @adapter = adapter
      @reconciler = reconciler
    end

    # league: ESPN league slug ("eng.1").
    # internal_season: the Season rows are filed into.
    # from_date/to_date: Date (or YYYYMMDD String) bounds before season clipping.
    #
    # Named `from_date`/`to_date` rather than `from`/`to`: inside the method a
    # keyword called `to` shadows Kernel#to, which breaks nothing obvious until
    # something calls it implicitly.
    def call(league:, internal_season:, from_date:, to_date:, trigger: 'manual')
      run = Sync::SyncRun.start!(kind: KIND, trigger: trigger)
      base = { provider: PROVIDER, league: league, season: internal_season.name }

      requested_from = coerce_date(from_date)
      requested_to = coerce_date(to_date)

      window = Sync::SeasonWindow.clip_to_season(
        internal_season.name, from: requested_from, to: requested_to
      )
      if window.nil?
        run.finish!(
          status: 'succeeded',
          details: base.merge(
            from: requested_from.iso8601, to: requested_to.iso8601,
            deferred: "window is outside the #{internal_season.name} season " \
                      "(#{Sync::SeasonWindow.start_of_season(internal_season.name)}.." \
                      "#{Sync::SeasonWindow.end_of_season(internal_season.name)})"
          )
        )
        return run
      end

      result = @client.scoreboard_dates(league: league, from_date: window.first, to_date: window.last)

      tally = Hash.new(0)
      conflicts = 0
      result.events.each do |payload|
        row = @adapter.normalize_fixture(payload)
        if row.nil?
          tally[:rejected] += 1
          next
        end

        # SEASON CHECK FIRST. ESPN scores events by ITS season, not by internal
        # season id, and the two disagree: a fixture we hold under 2025/26
        # (because that is the file football-data published it in) is served by
        # ESPN's scoreboard for its date with a 2026/27 season object. Handing it
        # to `internal_season` moved genuine fixtures between seasons. A row whose
        # own season is stated and contradicts the target is not ours to write.
        next unless season_matches?(payload, internal_season)

        outcome = @reconciler.apply_fixture(row, season: internal_season)
        tally[outcome.kind] += 1
        conflicts += 1 if outcome.kind == :conflict
      end

      run.finish!(
        status: 'succeeded',
        fetched: result.events.size,
        created: tally[:created],
        updated: tally[:updated],
        skipped: tally[:skipped],
        rejected: tally[:rejected],
        error: failure_text(tally[:rejected], conflicts),
        details: base.merge(
          from: window.first.iso8601,
          to: window.last.iso8601,
          requested_from: requested_from.iso8601,
          requested_to: requested_to.iso8601,
          days_searched: (result.days || {}).size,
          # Only the days that carried events, so the ledger stays readable while
          # still proving the empty days were asked about (days_searched).
          days_with_events: (result.days || {}).reject { |_day, count| count.zero? },
          conflicts: conflicts
        )
      )
      run
    rescue Import::EspnClient::TransientError => e
      finish_failed(run, "transient provider failure: #{e.message}")
    rescue Import::EspnClient::InvalidContentError => e
      finish_failed(run, "invalid provider response: #{e.message}")
    end

    private

    # True when ESPN's stated season for this event agrees with `internal_season`.
    #
    # Deliberately permissive when ESPN states nothing usable: an event without a
    # season block is imported as before, because refusing it would silently drop
    # real fixtures. The guard only rejects a POSITIVE contradiction.
    def season_matches?(payload, internal_season)
      stated = payload.dig("season", "year")
      return true if stated.blank?

      stated.to_s == Sync::SeasonWindow.start_year(internal_season.name).to_s
    end

    def coerce_date(value)
      return value if value.is_a?(Date)

      Date.strptime(value.to_s, '%Y%m%d')
    rescue Date::Error
      raise SeasonWindowError, "expected a Date or YYYYMMDD string, got #{value.inspect}"
    end

    def failure_text(rejected, conflicts)
      return nil if rejected.zero? && conflicts.zero?

      parts = []
      parts << "#{rejected} row(s) rejected (unmapped teams or unusable payload)" if rejected.positive?
      parts << "#{conflicts} conflict(s) with stored results, left unchanged" if conflicts.positive?
      parts.join('; ')
    end

    def finish_failed(run, message)
      run&.finish!(status: 'failed', error: message) if run&.status == 'running'
      run
    end
  end
end
