# Decides WHICH matches are due a result check, and enqueues one
# `MatchResultCheckJob` per match.
#
# WHY A SEPARATE JOB
# ------------------
# `MatchResultCheckJob` answers "what happened in this one match?". Something has
# to answer "which matches are due?" — and that question is a database query, not
# a provider request. Keeping them apart means the dispatcher can run every five
# minutes without spending a single ESPN request, and a provider outage cannot
# stop the queue from being filled.
#
# IT NEVER CALLS ESPN. Every provider request belongs to the individual job, which
# asks about exactly one event.
#
# ELIGIBILITY (all must hold)
# ---------------------------
#   - status is `scheduled` (a completed match is settled; a postponed one has no
#     result to fetch),
#   - kickoff is at least COMPLETION_BUFFER (2h15m) in the past,
#   - kickoff is within MAX_RETRY_WINDOW (24h) — past it the match is `expired`
#     and needs a human, not another request,
#   - an APPROVED ESPN event identifier exists,
#   - the competition maps to a verified ESPN league,
#   - no other check currently holds the match's lock.
#
# DEDUPLICATION
# -------------
# `Sync::ResultCheckLock` is a PostgreSQL advisory lock per match. Two dispatchers
# racing for the same match: exactly one enqueues. A worker that dies releases its
# lock with its connection, so a match is never permanently uncheckable.
class MatchResultDispatchJob < ApplicationJob
  queue_as :sync

  # The dispatcher is cheap and idempotent; a retry storm would only re-query.
  sidekiq_options retry: 1

  COMPLETION_BUFFER = MatchResultCheckJob::COMPLETION_BUFFER
  MAX_RETRY_WINDOW = MatchResultCheckJob::MAX_RETRY_WINDOW

  # A bounded batch. The dispatcher runs every five minutes, so a backlog drains
  # over several runs rather than in one unbounded burst of enqueues.
  BATCH_SIZE = 200

  def perform
    summary = { considered: 0, eligible: 0, enqueued: 0, duplicates: 0,
                invalid_mappings: 0, expired: 0, errors: [] }

    candidates.each do |match|
      summary[:considered] += 1

      if match.kickoff_at < MAX_RETRY_WINDOW.ago
        summary[:expired] += 1
        next
      end

      unless checkable?(match)
        summary[:invalid_mappings] += 1
        next
      end

      summary[:eligible] += 1

      if Sync::ResultCheckLock.acquire(match.id)
        MatchResultCheckJob.perform_later(match.id, 1)
        summary[:enqueued] += 1
      else
        summary[:duplicates] += 1
      end
    end

    record(summary)
    summary
  rescue ActiveRecord::StatementInvalid, PG::Error => e
    # A database failure must be reported, not raised: the ledger row is the
    # report, and a raised exception out of a scheduled job is how failures become
    # invisible.
    summary ||= { considered: 0, eligible: 0, enqueued: 0, duplicates: 0,
                  invalid_mappings: 0, expired: 0, errors: [] }
    summary[:errors] << "#{e.class.name.split('::').last}: #{e.message}"
    record(summary, status: "failed", error: summary[:errors].first)
    summary
  end

  private

  # One query, with the identifiers and competition preloaded. The eligibility
  # rules that need a join are expressed in SQL so the batch is bounded before
  # anything is loaded.
  def candidates
    Match.where(status: "scheduled")
         .where(kickoff_at: ...COMPLETION_BUFFER.ago)
         .includes(:competition)
         .order(:kickoff_at)
         .limit(BATCH_SIZE)
  end

  # Approved ESPN event id AND a verified league. Both are required: an event id
  # with no league cannot be requested, and a league with no event id cannot be
  # addressed.
  def checkable?(match)
    return false if espn_event_id(match).nil?

    EspnLeagueCoverage::VERIFIED[match.competition&.code].present?
  end

  def espn_event_id(match)
    @event_ids ||= ExternalIdentifier
                   .where(provider: Import::EspnAdapter::PROVIDER, review_state: "approved")
                   .where.not(external_id: nil)
                   .where.not(match_id: nil)
                   .pluck(:match_id, :external_id)
                   .to_h

    @event_ids[match.id]
  end

  def record(summary, status: "succeeded", error: nil)
    run = Sync::SyncRun.start!(kind: Sync::SyncRun::RESULT_KIND, trigger: "dispatch")
    run.finish!(
      status: status,
      fetched: summary[:considered],
      created: 0,
      updated: 0,
      skipped: summary[:duplicates] + summary[:invalid_mappings] + summary[:expired],
      rejected: summary[:invalid_mappings],
      error: error,
      details: {
        "dispatcher" => true,
        "considered" => summary[:considered],
        "eligible" => summary[:eligible],
        "enqueued" => summary[:enqueued],
        "duplicates" => summary[:duplicates],
        "invalid_mappings" => summary[:invalid_mappings],
        "expired" => summary[:expired],
        "errors" => summary[:errors]
      }
    )
    run
  rescue Sync::SyncRun::AlreadyRunning
    # A previous dispatch is still open. Not an error: the next run will do the
    # same work, and the ledger already has a row for the one in flight.
    nil
  end
end
