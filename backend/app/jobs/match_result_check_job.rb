# Checks ONE scheduled match for a published result.
#
# WHY ONE MATCH PER JOB
# ---------------------
# `Sync::EspnResultSynchronizer` is date-scoped: it fetches a whole scoreboard day
# and iterates every event. Checking a single finished fixture that way costs the
# same request but returns every other match on the day, and a caller that then
# iterates them can touch fixtures it was never asked about. This job asks ESPN
# about exactly one event (`Import::EspnClient#event`) and applies the answer
# through the same reconciliation rules (`#check_event`).
#
# ELIGIBILITY IS RECHECKED HERE, NOT TRUSTED FROM THE DISPATCHER
# --------------------------------------------------------------
# A queued job can run minutes later, after the match was completed by another
# path, rescheduled, or postponed. Every run reloads the row and re-derives
# eligibility from the CURRENT kickoff, so a stale enqueue is a no-op rather than
# a wrong write.
#
# WHAT IT NEVER DOES
# ------------------
#   - create a fixture,
#   - overwrite a trusted completed result (the reconciler returns `:conflict`),
#   - accept an event that resolves to a different match,
#   - treat "kickoff has passed" as "the match has finished",
#   - create or change predictions,
#   - retry past the configured window.
#
# RETRY POLICY
# ------------
# The dispatcher only enqueues after `COMPLETION_BUFFER` (2h15m) past kickoff. If
# the provider has no final result yet, the job re-enqueues itself after
# `RETRY_INTERVAL` (30 min) until `MAX_RETRY_WINDOW` (24h) past kickoff, after
# which it records `unresolved` for investigation instead of retrying forever.
class MatchResultCheckJob < ApplicationJob
  queue_as :sync

  # A provider outage is worth a few attempts, but the job re-enqueues itself for
  # "not published yet", so Sidekiq's own retry must stay small or the two
  # mechanisms multiply.
  sidekiq_options retry: 2

  COMPLETION_BUFFER = 2.hours + 15.minutes
  RETRY_INTERVAL = 30.minutes
  MAX_RETRY_WINDOW = 24.hours

  # Outcomes recorded in the ledger. A closed set, so a report can group by it.
  OUTCOMES = %w[completed unchanged conflict postponed rescheduled rejected
                provider_error unresolved ineligible].freeze

  # `ApplicationJob` takes no arguments, so the collaborators are optional
  # keywords with defaults rather than a positional signature. Sidekiq always
  # constructs the job with no arguments; the keywords exist for tests.
  #
  # `*args` carries the PERFORM arguments. In this ActiveJob version
  # `perform_later(a, b)` forwards them to `new`, so a constructor that accepted
  # only keywords raised "wrong number of arguments (given 2, expected 0)".
  #
  # THEY MUST BE PASSED TO `super`, NOT SWALLOWED. ActiveJob stores them in
  # `@arguments`, and that array is what gets serialised into the Sidekiq payload
  # and handed back to `perform`. Calling `super()` with no arguments left
  # `@arguments` empty, so every enqueued job carried `arguments: []` and died at
  # runtime with "wrong number of arguments (given 0, expected 1..2)".
  #
  # The unit specs did not catch this because they call `perform` directly on an
  # instance; only a real enqueue round-trip through Sidekiq exposes it.
  def initialize(*args, client: nil, synchronizer: nil)
    super(*args)
    @client = client
    @synchronizer = synchronizer
  end

  def perform(match_id, attempt = 1)
    # THE LOCK IS RELEASED HERE, ALWAYS.
    #
    # The dispatcher acquires the lock before enqueuing; this job is the only
    # thing that knows when the check is over. Without this `ensure`, every
    # completed check left its advisory lock and bookkeeping row behind — the
    # first live run leaked four of them, and each would have blocked that match
    # until the 15-minute TTL takeover.
    #
    # `ensure` covers the success path, every early return, and any exception.
    # Releasing a lock this process does not hold is a no-op, so a job that was
    # enqueued without a lock (a manual run) is unaffected.
    run_check(match_id, attempt)
  ensure
    Sync::ResultCheckLock.release(match_id)
  end

  private

  def run_check(match_id, attempt)
    match = Match.find_by(id: match_id)
    return record_skip(match_id, attempt, "match not found") if match.nil?

    # A COMPLETED match is settled. Re-fetching it would spend a provider request
    # to learn something the reconciler will refuse to change anyway, and the
    # dispatcher never selects one. It is recorded as `ineligible` so the ledger
    # still explains why nothing happened.
    #
    # A conflict on an ALREADY-COMPLETED match is detected by the date-scoped
    # `results:sync` run, which is the path that compares whole days; this job is
    # for fixtures that have no result yet.
    return record_skip(match.id, attempt, "match is completed") if match.status == "completed"

    reason = ineligibility(match)
    return record_skip(match.id, attempt, reason) if reason

    event_id = espn_event_id(match)
    return record_skip(match.id, attempt, "no approved ESPN event identifier") if event_id.nil?

    league = espn_league(match)
    return record_skip(match.id, attempt, "no ESPN league for this competition") if league.nil?

    check(match, event_id, league, attempt)
  end

  def client
    @client ||= Import::EspnClient.new
  end

  def synchronizer
    @synchronizer ||= Sync::EspnResultSynchronizer.new(client: client)
  end

  # Nil when the match may be checked; otherwise the reason it may not.
  #
  # The retry window is checked FIRST among the time conditions: a match past the
  # window is `unresolved`, not "not yet due", and the two must not be reported as
  # the same thing.
  def ineligibility(match)
    return "match is #{match.status}, not scheduled" unless match.status == "scheduled"
    return "kickoff is unknown" if match.kickoff_at.nil?
    return "retry window of #{MAX_RETRY_WINDOW.inspect} has elapsed" if match.kickoff_at < MAX_RETRY_WINDOW.ago
    return "kickoff has not passed the completion buffer" if match.kickoff_at > COMPLETION_BUFFER.ago

    nil
  end

  def espn_event_id(match)
    ExternalIdentifier.where(provider: Import::EspnAdapter::PROVIDER, match_id: match.id)
                      .where.not(external_id: nil)
                      .order(:id)
                      .first&.external_id
  end

  # The ESPN slug for the match's competition, from the same verified map the
  # discovery job uses. A competition with no verified feed is not checkable.
  def espn_league(match)
    code = match.competition&.code
    return nil if code.blank?

    EspnLeagueCoverage::VERIFIED[code]
  end

  def check(match, event_id, league, attempt)
    return record_skip(match.id, attempt, "no approved ESPN event identifier") if event_id.nil?
    return record_skip(match.id, attempt, "no ESPN league for this competition") if league.nil?

    payload = client.event(league: league, event_id: event_id)
    report = synchronizer.check_event(event_payload: payload, match: match,
                                      season: match.season, apply: true)

    outcome = classify(report)
    record(match, event_id, attempt, outcome, report)
    schedule_retry(match, attempt) if outcome == "unchanged"
    outcome
  rescue Import::EspnClient::TransientError => e
    record(match, event_id, attempt, "provider_error", nil, error: e.message)
    schedule_retry(match, attempt)
    "provider_error"
  rescue Import::EspnClient::InvalidContentError => e
    # A permanent provider answer (404, malformed payload). Retrying cannot fix it.
    record(match, event_id, attempt, "provider_error", nil, error: e.message)
    "provider_error"
  end

  def classify(report)
    return "conflict" if report.conflicts.any?
    return "completed" if report.completed.any?
    return "postponed" if report.postponed.any?
    return "rescheduled" if report.rescheduled.any?
    return "rejected" if report.rejected.any?

    "unchanged"
  end

  def schedule_retry(match, attempt)
    return if match.kickoff_at.nil?
    return if match.kickoff_at < MAX_RETRY_WINDOW.ago

    # `ConfiguredJob#perform_later` calls `@job_class.new(*args).enqueue(options)`,
    # so the perform arguments reach the CONSTRUCTOR — which is why `initialize`
    # accepts and ignores them. `set` also needs an explicit queue here: without
    # one it raises `undefined method 'map' for nil` while building the job.
    self.class.set(queue: queue_name.to_s, wait: RETRY_INTERVAL)
              .perform_later(match.id, attempt + 1)
  end

  # One ledger row per attempt. `kind: results` keeps it in the same operational
  # view as the date-scoped runs, and the details carry the per-attempt facts an
  # operator needs without storing the provider payload.
  def record(match, event_id, attempt, outcome, report, error: nil)
    run = Sync::SyncRun.start!(kind: Sync::SyncRun::MATCH_CHECK_KIND, trigger: "match_check")
    run.finish!(
      status: outcome == "provider_error" ? "failed" : "succeeded",
      fetched: 1,
      created: 0,
      updated: %w[completed postponed rescheduled].include?(outcome) ? 1 : 0,
      skipped: outcome == "unchanged" ? 1 : 0,
      rejected: outcome == "rejected" ? 1 : 0,
      error: error,
      details: {
        "match_id" => match.id,
        "event_id" => event_id,
        "attempt" => attempt,
        "outcome" => outcome,
        "match_status" => match.reload.status,
        "score" => [match.home_score, match.away_score],
        "conflicts" => report&.conflicts&.map(&:to_h) || [],
        # WHY a row was rejected. Without this the ledger said `rejected` and
        # nothing else, which is exactly the kind of report that cannot be acted
        # on — the first live run produced two of them and the reason was lost.
        "rejections" => report&.rejected&.map(&:to_h) || [],
      },
    )
    run
  end

  # A run that never reached the provider still leaves a trace, so "why was this
  # match never checked?" has an answer in the ledger.
  def record_skip(match_id, attempt, reason)
    # A match past the retry window is a DIFFERENT fact from one that is simply not
    # due yet: the first needs a human, the second needs time. Collapsing them into
    # `ineligible` would hide the fixtures that will never resolve on their own.
    outcome = reason.to_s.include?("retry window") ? "unresolved" : "ineligible"

    run = Sync::SyncRun.start!(kind: Sync::SyncRun::MATCH_CHECK_KIND, trigger: "match_check")
    run.finish!(status: "succeeded", fetched: 0, created: 0, updated: 0, skipped: 1,
                rejected: 0,
                details: { "match_id" => match_id, "attempt" => attempt,
                           "outcome" => outcome, "reason" => reason })
    outcome
  end
end
