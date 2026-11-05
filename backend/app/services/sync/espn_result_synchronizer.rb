require "set"

module Sync
  # Collects FINAL RESULTS from ESPN for one league/date and reconciles them with
  # the stored fixtures.
  #
  # WHY THIS IS NOT `EspnSynchronizer`
  # ---------------------------------
  # `EspnSynchronizer` is a fixture import: it reports created/updated/skipped and
  # treats a day of events as a fixture refresh. A result run has different
  # questions to answer — *which* event is a final result, which conflicts with a
  # stored result, which fixture moved — and an operator must be able to read those
  # answers BEFORE anything is written. A `dry_run` flag bolted onto the fixture
  # synchronizer would have welded two different reports onto one counters row.
  #
  # WHAT IS REUSED, NOT REIMPLEMENTED
  # ---------------------------------
  #   Import::EspnClient             provider access (gzip, retries, error classes)
  #   Import::EspnAdapter            event -> canonical row (status precedence)
  #   Import::ApiFootballReconciler  identity, duplicate prevention, reschedule
  #                                  handling, completed-result precedence
  #   Sync::SyncRun                  the ledger, kind `results`
  #
  # The reconciler already guarantees a stored completed result is never
  # overwritten by a different score — it returns `:conflict`. This class does not
  # second-guess that; it SURFACES the conflict list, because "succeeded with 1
  # conflict" and "succeeded" are different facts to anyone collecting evidence.
  #
  # PREVIEW BY DEFAULT
  # ------------------
  # `preview` writes NOTHING to matches — not even a provider mapping — and records
  # what it would do. `call` applies. Both write a ledger row: a preview that left
  # no trace would be indistinguishable from a run that never happened.
  #
  # WHAT IT NEVER DOES
  # ------------------
  #   - create a fixture (discovery owns creation),
  #   - overwrite a stored completed result,
  #   - invent a score for a postponed/abandoned/cancelled fixture,
  #   - write to any other competition's fixtures.
  class EspnResultSynchronizer
    KIND = Sync::SyncRun::RESULT_KIND
    PROVIDER = Import::EspnAdapter::PROVIDER

    # Adapter statuses meaning "this event is over and carries no score". The
    # adapter sets them; this set only decides how the run reports them.
    #
    # `cancelled` is in this list on purpose: the adapter maps an abandoned match to
    # `cancelled` (ESPN reports it in the same family), and the run must report it
    # as an event with no result rather than as a missing update.
    TERMINAL_NON_RESULTS = %w[postponed cancelled abandoned].freeze

    # One inspected event. `action` is the human-facing verb: would_complete,
    # unchanged, conflict, would_reschedule, would_postpone, skipped, rejected.
    Entry = Struct.new(:match_id, :provider_event, :action, :detail, keyword_init: true) do
      # String keys, ALWAYS. The ledger column is jsonb and an operator reads it as
      # JSON: a detail hash that still carries symbol keys serialises as
      # `"stored_score": [5, 5]` next to `:stored_score`-style output in a console
      # dump, which is exactly how a conflict report becomes unreadable at the
      # moment somebody needs it. Encoding happens here, once, not at each caller.
      def to_h
        detail_hash = (detail || {}).to_h { |key, value| [key.to_s, value] }
        { "match_id" => match_id, "provider_event" => provider_event,
          "action" => action.to_s }.merge(detail_hash)
      end
    end

    class Report
      ATTRS = %i[fetched completed unchanged conflicts rescheduled postponed rejected ignored
                 planned mode season league date].freeze

      attr_reader(*ATTRS)

      def initialize(fetched:, completed:, unchanged:, conflicts:, rescheduled:, postponed:,
                     rejected:, ignored:, planned:, mode:, season:, league:, date:)
        @fetched = fetched
        @completed = completed
        @unchanged = unchanged
        @conflicts = conflicts
        @rescheduled = rescheduled
        @postponed = postponed
        @rejected = rejected
        @ignored = ignored
        @planned = planned
        @mode = mode
        @season = season
        @league = league
        @date = date
      end

      def inspected
        completed.size + unchanged.size + conflicts.size + rescheduled.size +
          postponed.size + rejected.size + ignored.size
      end

      def applied?
        mode == "apply"
      end

      def summary
        "fetched=#{fetched} inspected=#{inspected} completed=#{completed.size} " \
          "unchanged=#{unchanged.size} conflicts=#{conflicts.size} " \
          "rescheduled=#{rescheduled.size} postponed=#{postponed.size} " \
          "rejected=#{rejected.size} ignored=#{ignored.size}"
      end

      def to_h
        {
          "mode" => mode, "league" => league, "season" => season, "date" => date,
          "fetched" => fetched, "inspected" => inspected,
          "completed" => completed.map(&:to_h),
          "unchanged" => unchanged.size,
          "conflicts" => conflicts.map(&:to_h),
          "rescheduled" => rescheduled.map(&:to_h),
          "postponed" => postponed.map(&:to_h),
          "rejected" => rejected.map(&:to_h),
          "ignored" => ignored.size,
          "planned" => planned.map(&:to_h)
        }
      end
    end

    def initialize(client: Import::EspnClient.new,
                   adapter: Import::EspnAdapter.new,
                   reconciler: Import::ApiFootballReconciler.new)
      @client = client
      @adapter = adapter
      @reconciler = reconciler
    end

    # Writes nothing to matches. Returns the Report of what `call` would do.
    def preview(league:, season:, date: nil, trigger: "manual")
      run = Sync::SyncRun.start!(kind: KIND, trigger: trigger)
      report = build_report(league: league, season: season, date: date, apply: false)
      finish(run, report)
    rescue Import::EspnClient::TransientError, Import::EspnClient::InvalidContentError => e
      finish_failed(run, e)
    end

    # Applies. Conflicts are reported and left untouched.
    def call(league:, season:, date: nil, trigger: "manual")
      run = Sync::SyncRun.start!(kind: KIND, trigger: trigger)
      report = build_report(league: league, season: season, date: date, apply: true)
      finish(run, report)
    rescue Import::EspnClient::TransientError, Import::EspnClient::InvalidContentError => e
      finish_failed(run, e)
    end

    # ONE event, already fetched, for ONE known match.
    #
    # WHY NOT `call(league:, season:, date:)`
    # ---------------------------------------
    # That entry point is date-scoped: it fetches a whole scoreboard day and
    # iterates every event, so checking one fixture would touch every other match
    # on that day. This method takes the payload the caller already fetched and
    # applies the SAME rules — `decide`, `classify`, `apply_fixture` — to it.
    #
    # THE ASSOCIATION GUARD IS THE POINT. `decide` resolves the event to a match by
    # provider identity or teams+day. If that resolution lands on a DIFFERENT match
    # than the caller asked about, the answer is refused: applying it would write a
    # result to a fixture nobody checked. This is the one rule a single-match path
    # must add on top of the date-scoped one.
    #
    # Returns a Report with exactly one entry in one bucket, so the caller can
    # classify the outcome without re-deriving it.
    def check_event(event_payload:, match:, season:, apply: true)
      row = @adapter.normalize_fixture(event_payload)
      return single(:rejected, match, reason: "unusable payload") if row.nil?

      verdict = decide(row, season)

      if verdict[:match].nil?
        return single(:rejected, match, reason: verdict[:reason] || "unknown fixture")
      end

      unless verdict[:match].id == match.id
        return single(:rejected, match,
                      reason: "event resolves to match #{verdict[:match].id}, not #{match.id}")
      end

      # TEAM AGREEMENT. `resolve_match` matches by provider id FIRST, so an event
      # whose id is linked to this match but whose payload describes different
      # clubs would still resolve here and be written. The id is a claim; the
      # teams are the evidence. A payload that disagrees with the stored fixture
      # is refused rather than applied.
      unless teams_agree?(row, match)
        return single(:rejected, match,
                      reason: "event teams do not match the stored fixture")
      end

      # APPLY THROUGH THE RECONCILER, BUT ONLY TO THE MATCH WE VERIFIED.
      #
      # `apply_fixture` re-resolves the row by provider id and would happily write
      # to whatever it finds. The association guard above proved the event belongs
      # to `match`, so the write is performed against that row directly, using the
      # reconciler's own `planned_changes` — the same rule set, one target.
      if apply && verdict[:kind] == :updated && verdict[:changes].present?
        match.with_lock do
          match.update!(verdict[:changes])
        end
        verdict = verdict.merge(match: match)
      end

      buckets = Hash.new { |hash, key| hash[key] = [] }
      planned = []
      classify(verdict, row, buckets, planned)

      Report.new(fetched: 1, completed: buckets[:completed], unchanged: buckets[:unchanged],
                 conflicts: buckets[:conflicts], rescheduled: buckets[:rescheduled],
                 postponed: buckets[:postponed], rejected: buckets[:rejected],
                 ignored: buckets[:ignored], planned: planned,
                 mode: apply ? "apply" : "preview", season: season.name,
                 league: nil, date: nil)
    end

    private

    # A one-entry Report, for the paths that never reach `classify`.
    def single(kind, match, reason: nil)
      entry = Entry.new(match_id: match&.id, provider_event: nil, action: kind,
                        detail: { reason: reason }.compact)
      Report.new(fetched: 1, completed: [], unchanged: [], conflicts: [], rescheduled: [],
                 postponed: [], rejected: kind == :rejected ? [entry] : [],
                 ignored: kind == :rejected ? [] : [entry], planned: [],
                 mode: "apply", season: nil, league: nil, date: nil)
    end

    def build_report(league:, season:, date:, apply:)
      result = @client.scoreboard(league: league, date: date&.strftime("%Y%m%d"))
      events = Array(result.events)

      buckets = Hash.new { |hash, key| hash[key] = [] }
      planned = []

      events.each do |payload|
        row = @adapter.normalize_fixture(payload)
        if row.nil?
          buckets[:rejected] << entry(nil, payload["id"], :rejected, reason: "unusable payload")
          next
        end

        verdict = decide(row, season)

        if verdict[:match].nil? && verdict[:kind] != :skipped
          buckets[:rejected] << entry(nil, row.provider_key, :rejected,
                                      reason: verdict[:reason] || "unresolved club or unknown fixture")
          next
        end

        # Apply only when the decision is a write. Preview never calls the reconciler.
        if apply && %i[updated].include?(verdict[:kind]) && verdict[:changes].present?
          applied = @reconciler.apply_fixture(row, season: season)
          verdict = verdict.merge(match: applied.match || verdict[:match],
                                  kind: applied.kind == :conflict ? :conflict : verdict[:kind])
        end

        classify(verdict, row, buckets, planned)
      end

      Report.new(fetched: events.size, completed: buckets[:completed],
                 unchanged: buckets[:unchanged], conflicts: buckets[:conflicts],
                 rescheduled: buckets[:rescheduled], postponed: buckets[:postponed],
                 rejected: buckets[:rejected], ignored: buckets[:ignored], planned: planned,
                 mode: apply ? "apply" : "preview", season: season.name,
                 league: league, date: date&.iso8601)
    end

    # The payload's clubs, resolved through approved mappings, must be the stored
    # fixture's clubs. An unmapped club is not agreement.
    def teams_agree?(row, match)
      home_team = @reconciler.send(:team_for, row.provider, row.home_provider_team_id)
      away_team = @reconciler.send(:team_for, row.provider, row.away_provider_team_id)

      home_team&.id == match.home_team_id && away_team&.id == match.away_team_id
    end

    # Read-only classification that mirrors `ApiFootballReconciler#reconcile` and
    # `#planned_changes` exactly. It does not duplicate their RULES — it calls them
    # through the reconciler's own private helpers, so there is one implementation
    # of "is this a conflict" in the codebase.
    def decide(row, season)
      home_team = @reconciler.send(:team_for, row.provider, row.home_provider_team_id)
      away_team = @reconciler.send(:team_for, row.provider, row.away_provider_team_id)
      return { kind: :rejected, match: nil, reason: "unmapped club" } if home_team.nil? || away_team.nil?

      match, = @reconciler.send(:resolve_match, row, home_team, away_team, season)
      # No match: discovery has not created it yet. A result run must not create it.
      return { kind: :skipped, match: nil, reason: "unknown fixture" } if match.nil?

      # ASSOCIATION CHECK. `resolve_match` finds a fixture by provider identity or by
      # teams + day, and neither path is scoped to `season`. Without this guard a
      # result run for 2025/26 would happily reconcile a 2026/27 fixture that the
      # provider happens to report under the same id, changing the wrong season's
      # data. A match belonging to another season is treated as unknown here — it
      # is not an error, it simply is not this run's fixture.
      unless match.season_id == season.id
        return { kind: :skipped, match: nil, reason: "fixture belongs to season #{match.season_id}" }
      end

      prior = { status: match.status, kickoff_at: match.kickoff_at,
                home_score: match.home_score, away_score: match.away_score }

      if match.status == "completed"
        same = row.status == "completed" && match.home_score == row.home_score &&
               match.away_score == row.away_score
        return same ? { kind: :skipped, match: match, prior: prior }
                    : { kind: :conflict, match: match, prior: prior }
      end

      return { kind: :conflict, match: match, prior: prior } if row.status == "completed" && row.home_score.nil?

      changes = @reconciler.send(:planned_changes, match, row)
      return { kind: :skipped, match: match, prior: prior } if changes.empty?

      { kind: :updated, match: match, prior: prior, changes: changes }
    end

    def classify(verdict, row, buckets, planned)
      match_id = verdict[:match]&.id
      base = { match_id: match_id, provider_event: row.provider_key }

      case verdict[:kind]
      when :conflict
        prior = verdict[:prior] || {}
        buckets[:conflicts] << entry(match_id, row.provider_key, :conflict,
                                     stored_status: prior[:status], provider_status: row.status,
                                     stored_score: [prior[:home_score], prior[:away_score]],
                                     provider_score: [row.home_score, row.away_score])
      when :skipped
        if verdict[:match]&.status == "completed"
          buckets[:unchanged] << entry(match_id, row.provider_key, :unchanged)
        else
          buckets[:ignored] << entry(match_id, row.provider_key, :skipped,
                                     reason: verdict[:reason] || "no change")
        end
      when :updated
        if row.status == "completed"
          buckets[:completed] << entry(match_id, row.provider_key, :completed,
                                       score: [row.home_score, row.away_score],
                                       from: verdict[:prior]&.dig(:status))
          planned << Entry.new(**base, action: :would_complete, detail: { score: [row.home_score, row.away_score] })
          return
        end

        # Classification of this row's other transitions. Which provider event caused
        # which change is a different question from whether the change is itself
        # safe; `decide` has already answered that by consulting the reconciler.
        prior_kickoff = verdict[:prior]&.dig(:kickoff_at)
        if row.kickoff_at && prior_kickoff && prior_kickoff.to_i != row.kickoff_at.to_i
          buckets[:rescheduled] << entry(match_id, row.provider_key, :rescheduled,
                                         from_kickoff: prior_kickoff.utc.iso8601,
                                         to_kickoff: row.kickoff_at.utc.iso8601)
          planned << Entry.new(**base, action: :would_reschedule,
                               detail: { to_kickoff: row.kickoff_at.utc.iso8601 })
          return
        end

        # A status-only change (scheduled -> in_progress, for example) is recorded
        # as an update but is not a result, a reschedule or a postponement. It is
        # counted separately so the report adds up: `inspected` must equal the
        # number of events the provider returned.
        #
        # A postponement/cancellation IS called out here: it is the one status
        # change an operator must know about, because it voids the fixture for
        # prospective purposes without producing any result to score.
        if TERMINAL_NON_RESULTS.include?(row.status)
          buckets[:postponed] << entry(match_id, row.provider_key, row.status.to_sym,
                                       from: verdict[:prior]&.dig(:status))
          planned << Entry.new(**base, action: :"would_mark_#{row.status}")
        else
          buckets[:ignored] << entry(match_id, row.provider_key, :status_only,
                                     status: row.status, from: verdict[:prior]&.dig(:status))
        end
      else
        buckets[:ignored] << entry(match_id, row.provider_key, :ignored)
      end
    end

    def entry(match_id, provider_event, action, detail = {})
      Entry.new(match_id: match_id, provider_event: provider_event, action: action, detail: detail)
    end

    # Ledger, then the Report. A preview records `skipped = fetched` and
    # `updated = 0` so nobody can mistake its row for an import that changed
    # something.
    def finish(run, report)
      changed = report.completed.size + report.rescheduled.size + report.postponed.size
      run&.finish!(
        status: "succeeded",
        fetched: report.fetched,
        created: 0,
        updated: report.applied? ? changed : 0,
        skipped: report.applied? ? report.unchanged.size : report.fetched,
        rejected: report.rejected.size,
        error: conflict_error(report),
        details: report.to_h
      )
      report
    end

    def conflict_error(report)
      return nil if report.conflicts.empty?

      "#{report.conflicts.size} result conflict(s) with stored matches, left unchanged for review"
    end

    def finish_failed(run, error)
      message = "#{error.class.name.split('::').last}: #{error.message}"
      run&.finish!(status: "failed", error: message) if run&.status == "running"
      # A provider failure is reported, not raised: the ledger row IS the report,
      # and an operator reading a rake task needs it rather than a stack trace.
      nil
    end
  end
end
