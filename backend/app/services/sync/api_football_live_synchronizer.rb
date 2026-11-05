module Sync
  # Live fixture polling: `GET /fixtures?live=all`.
  #
  # ONE request returns every live fixture across every league, so the cost of a
  # poll is constant regardless of how many matches are in progress. With a
  # 100-request/day free plan, that is the only affordable live design: polling
  # per fixture, or per competition, would exhaust the quota in an afternoon.
  #
  # WHAT IT MAY WRITE
  # -----------------
  # Status and the CURRENT score, and nothing else. A live match's score is not a
  # final result, so it is written as the current score and the match is left
  # `in_progress`; promotion to `completed` happens only when the provider says
  # FT, through the same reconciliation rules as the daily result import.
  #
  # Only fixtures already mapped to an internal match are touched. An unmapped
  # live fixture is counted as `skipped`, never created: creating it would attach
  # a new match to an unknown competition/season and could duplicate a fixture
  # that the daily import will create properly with its real season.
  class ApiFootballLiveSynchronizer
    KIND = Sync::SyncRun::FIXTURE_KIND
    PROVIDER = "api_football".freeze

    def initialize(client: Import::ApiFootballClient.new,
                   adapter: Import::ApiFootballAdapter.new,
                   reconciler: Import::ApiFootballReconciler.new)
      @client = client
      @adapter = adapter
      @reconciler = reconciler
    end

    def call(trigger: "schedule")
      run = Sync::SyncRun.start!(kind: KIND, trigger: trigger)
      tally = Hash.new(0)
      terminal = 0

      result = @client.get("/fixtures", query: { live: "all" })

      result.records.each do |payload|
        row = @adapter.normalize_fixture(payload)
        if row.nil?
          tally[:rejected] += 1
          next
        end

        mapping = ExternalIdentifier.find_by(provider: PROVIDER, external_id: row.provider_key)
        if mapping&.match.nil?
          # Not ours (or not yet mapped). The daily import owns creation.
          tally[:skipped] += 1
          next
        end

        match = mapping.match
        # A live payload carries no final score by design (the adapter strips
        # it), so the reconciler records the status transition only.
        outcome = @reconciler.apply_fixture(row, season: match.season)
        tally[outcome.kind] += 1
        terminal += 1 if %w[completed cancelled].include?(match.reload.status)
      end

      run.finish!(
        status: "succeeded",
        fetched: result.records.size,
        created: 0,
        updated: tally[:updated],
        skipped: tally[:skipped],
        rejected: tally[:rejected],
        details: {
          provider: PROVIDER,
          live_discovered: result.records.size,
          matched_internal: tally[:updated] + tally[:skipped],
          terminal_during_poll: terminal,
          quota_remaining: result.quota_remaining,
        },
      )
      run
    rescue Import::ApiFootballClient::RateLimitError, Import::ApiFootballClient::TransientError => e
      # Live polling is best-effort: the next tick retries, and the daily import
      # remains the source of truth. A failed poll must never fail loudly enough
      # to stop the schedule.
      run&.finish!(status: "failed", error: e.message)
      run
    rescue Import::ApiFootballClient::ConfigurationError,
           Import::ApiFootballClient::AuthenticationError,
           Import::ApiFootballClient::ApiError,
           Import::ApiFootballClient::InvalidContentError => e
      run&.finish!(status: "failed", error: e.message)
      run
    end
  end
end
