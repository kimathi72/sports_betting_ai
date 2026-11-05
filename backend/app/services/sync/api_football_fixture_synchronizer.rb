module Sync
  # Ingests one league season from API-Football into the canonical tables.
  #
  # Reuses the existing SyncRun ledger for observability — no second monitoring
  # path. `kind` is registered below so the status endpoint reports it alongside
  # the CSV synchronizers.
  #
  # QUOTA DISCIPLINE
  # ----------------
  # The account allows 100 requests per day and 10 per minute. One call imports
  # a whole season (380 fixtures), so the design fetches per season, never per
  # fixture, and refuses to start when the remaining quota is too low to matter.
  class ApiFootballFixtureSynchronizer
    KIND = Sync::SyncRun::FIXTURE_KIND
    PROVIDER = 'api_football'.freeze

    # Below this, a failed run would strand the integration for the rest of the
    # day, so we skip and say why rather than burning the last requests.
    MINIMUM_QUOTA = 2

    Outcome = Struct.new(:status, :fetched, :created, :updated, :skipped, :rejected,
                         :conflicts, :error, keyword_init: true)

    def initialize(client: Import::ApiFootballClient.new,
                   adapter: Import::ApiFootballAdapter.new,
                   reconciler: Import::ApiFootballReconciler.new)
      @client = client
      @adapter = adapter
      @reconciler = reconciler
    end

    # league: provider league id, season: provider season year, internal_season:
    # the Season row to attach new fixtures to.
    def call(league:, season:, internal_season:, trigger: 'schedule')
      run = Sync::SyncRun.start!(kind: KIND, trigger: trigger)
      started = Time.current
      tally = Hash.new(0)

      result = @client.get('/fixtures', query: { league: league, season: season })
      rows = result.records

      if result.quota_remaining && result.quota_remaining < 0
        run.finish!(status: 'failed', error: 'provider quota exhausted', details: {})
        return run
      end

      conflicts = 0
      rows.each do |payload|
        normalized = @adapter.normalize_fixture(payload)
        outcome = @reconciler.apply_fixture(normalized, season: internal_season)
        tally[outcome.kind] += 1
        conflicts += 1 if outcome.kind == :conflict
      end

      rejected = tally[:rejected]
      failed = rows.empty? || (rejected + conflicts) == rows.size && rows.any?

      run.finish!(
        status: failed ? 'failed' : 'succeeded',
        fetched: rows.size,
        created: tally[:created],
        updated: tally[:updated],
        skipped: tally[:skipped],
        rejected: rejected,
        error: failure_text(rows, rejected, conflicts),
        details: {
          provider: PROVIDER,
          league: league,
          season: season,
          conflicts: conflicts,
          quota_remaining: result.quota_remaining,
          quota_limit: result.quota_limit,
          duration_seconds: (Time.current - started).round(1)
        }
      )
      run
    rescue Import::ApiFootballClient::RateLimitError => e
      finish_failed(run, "rate limited: #{e.message}")
    rescue Import::ApiFootballClient::ApiError => e
      # A plan restriction (e.g. a season the free tier cannot serve) is
      # permanent: retrying today would only spend quota to get the same answer.
      finish_failed(run, "provider error: #{e.message}")
    rescue Import::ApiFootballClient::ConfigurationError,
           Import::ApiFootballClient::AuthenticationError => e
      finish_failed(run, "configuration/auth error: #{e.message}")
    rescue Import::ApiFootballClient::InvalidContentError => e
      finish_failed(run, "invalid provider response: #{e.message}")
    rescue Import::ApiFootballClient::TransientError => e
      finish_failed(run, "transient provider failure: #{e.message}")
    end

    private

    # A partially-imported run is still a success: the imported rows are valid,
    # and the rejected count tells the operator what was skipped.
    def failure_text(rows, rejected, conflicts)
      return 'provider returned no fixtures (check league/season access on this plan)' if rows.empty?

      # A clean run must report nil, not a sentence reading "0 row(s) rejected":
      # an operator scanning the ledger for failures should not have to parse
      # prose to discover there were none.
      return nil if rejected.zero? && conflicts.zero?

      parts = []
      parts << "#{rejected} row(s) rejected (unmapped teams or unusable payload)" if rejected.positive?
      parts << "#{conflicts} conflict(s) with stored results, left unchanged" if conflicts.positive?
      parts.join('; ')
    end

    def finish_failed(run, message)
      run&.finish!(status: 'failed', error: message)
      run
    end
  end
end
