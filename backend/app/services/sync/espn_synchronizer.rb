module Sync
  # Ingests one ESPN league from a scoreboard request into canonical tables.
  #
  # REUSES EVERYTHING. The rows go through `Import::ApiFootballReconciler`, which
  # already owns duplicate prevention, reschedule handling, the completed-result
  # precedence rule and provider-identity recording. A provider-specific write
  # path would double the rules that must stay correct.
  #
  # SOURCE-OF-TRUTH POLICY (see docs/data-providers.md):
  #   - A stored completed result is never overwritten by a different score from
  #     any provider. The reconciler already enforces this.
  #   - ESPN is the source for CURRENT-season fixtures and live status, because it
  #     is the only free provider that serves them.
  #   - ESPN never creates a team. An unmapped provider team is counted as
  #     `rejected` and reported, because guessing a club identity creates
  #     duplicates that are far more expensive than a missing mapping.
  class EspnSynchronizer
    KIND = Sync::SyncRun::FIXTURE_KIND
    PROVIDER = Import::EspnAdapter::PROVIDER

    def initialize(client: Import::EspnClient.new,
                   adapter: Import::EspnAdapter.new,
                   reconciler: Import::ApiFootballReconciler.new)
      @client = client
      @adapter = adapter
      @reconciler = reconciler
    end

    def call(league:, internal_season:, date: nil, trigger: "schedule")
      run = Sync::SyncRun.start!(kind: KIND, trigger: trigger)
      tally = Hash.new(0)
      conflicts = 0

      result = @client.scoreboard(league: league, date: date)

      result.events.each do |payload|
        row = @adapter.normalize_fixture(payload)
        if row.nil?
          tally[:rejected] += 1
          next
        end

        # The reconciler resolves by provider id, then by teams+day. A fixture
        # already imported from football-data.co.uk matches on the second path and
        # gains an ESPN mapping instead of being duplicated.
        outcome = @reconciler.apply_fixture(row, season: internal_season)
        tally[outcome.kind] += 1
        conflicts += 1 if outcome.kind == :conflict
      end

      run.finish!(
        status: "succeeded",
        fetched: result.events.size,
        created: tally[:created],
        updated: tally[:updated],
        skipped: tally[:skipped],
        rejected: tally[:rejected],
        error: failure_text(result.events.size, tally[:rejected], conflicts),
        details: {
          provider: PROVIDER,
          league: league,
          date: date,
          season: internal_season.name,
          conflicts: conflicts,
        },
      )
      run
    rescue Import::EspnClient::TransientError => e
      finish_failed(run, "transient provider failure: #{e.message}")
    rescue Import::EspnClient::InvalidContentError => e
      finish_failed(run, "invalid provider response: #{e.message}")
    end

    private

    def failure_text(fetched, rejected, conflicts)
      return "provider returned no events for this date/league" if fetched.zero?
      return nil if rejected.zero? && conflicts.zero?

      parts = []
      parts << "#{rejected} row(s) rejected (unmapped teams or unusable payload)" if rejected.positive?
      parts << "#{conflicts} conflict(s) with stored results, left unchanged" if conflicts.positive?
      parts.join("; ")
    end

    def finish_failed(run, message)
      run&.finish!(status: "failed", error: message) if run&.status == "running"
      run
    end
  end
end
