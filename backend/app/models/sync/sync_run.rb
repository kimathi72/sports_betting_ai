module Sync
  # One synchronization attempt, used as the operational ledger.
  #
  # A run is opened before any provider request and closed with its counts and
  # outcome. If the process dies mid-run the row stays `running`, and the next
  # scheduled attempt marks it abandoned (see STALE_AFTER) instead of blocking
  # forever — a crashed import must not silence the scheduler permanently.
  class SyncRun < ApplicationRecord
    self.table_name = 'sync_runs'

    KINDS = %w[fixtures results].freeze
    STATUSES = %w[running succeeded failed].freeze

    # A daily job that is still "running" after this long did not finish. The
    # window is deliberately longer than any plausible provider request so a slow
    # but healthy run is never declared dead.
    STALE_AFTER = 2.hours

    # How long before a kind's last success is considered stale. The schedule runs
    # daily, so two days without success means at least one run was missed.
    STALE_AFTER_SUCCESS = 36.hours

    class AlreadyRunning < StandardError; end

    validates :kind, inclusion: { in: KINDS }
    validates :status, inclusion: { in: STATUSES }
    validates :trigger, presence: true

    scope :for_kind, ->(kind) { where(kind: kind) }
    scope :running, -> { where(status: 'running') }
    scope :succeeded, -> { where(status: 'succeeded') }

    def self.start!(kind:, trigger:)
      unless KINDS.include?(kind.to_s)
        raise ArgumentError, "unknown sync kind #{kind.inspect}; expected #{KINDS.join(', ')}"
      end

      # Reclaim a run abandoned by a crashed worker first, so a dead process
      # cannot block this kind indefinitely.
      close_abandoned!(kind)

      create!(kind: kind.to_s, trigger: trigger.to_s, status: 'running', started_at: Time.current)
    rescue ActiveRecord::RecordNotUnique
      # The partial unique index rejected a second open run for this kind.
      raise AlreadyRunning, "a #{kind} synchronization is already running"
    end

    def self.close_abandoned!(kind)
      for_kind(kind).running
                 .where(started_at: ...(Time.current - STALE_AFTER))
                 .find_each do |run|
        run.finish!(status: 'failed',
                    error: 'abandoned: the process did not finish within ' \
                           "#{STALE_AFTER.inspect} (stale run reclaimed by a later attempt)")
      end
    end

    def finish!(status:, fetched: nil, created: nil, updated: nil, skipped: nil,
                rejected: nil, error: nil, details: nil)
      update!(
        status: status.to_s,
        finished_at: Time.current,
        fetched: fetched.nil? ? self.fetched : fetched.to_i,
        created: created.nil? ? self.created : created.to_i,
        updated: updated.nil? ? self.updated : updated.to_i,
        skipped: skipped.nil? ? self.skipped : skipped.to_i,
        rejected: rejected.nil? ? self.rejected : rejected.to_i,
        last_error: error.nil? ? last_error : self.class.redact(error),
        details: details.nil? ? self.details : details
      )
    end

    def running? = status == 'running'
    def succeeded? = status == 'succeeded'
    def failed? = status == 'failed'

    def duration_seconds
      return nil if finished_at.nil? || started_at.nil?

      (finished_at - started_at).to_f
    end

    # Anything shaped like a credential is removed before it reaches the database.
    # This table is read by operators and potentially surfaced by a status
    # endpoint; a provider URL with an embedded key must never land here.
    REDACTIONS = [
      /(apikey|api_key|key|token|secret|password|signature|auth)=([^&\s]+)/i,
      %r{(https?://[^:/\s]+):[^@\s]+@}i
    ].freeze

    def self.redact(text)
      return text if text.nil?

      REDACTIONS.reduce(text.to_s) do |acc, pattern|
        acc.gsub(pattern) do
          if Regexp.last_match(2)
            "#{Regexp.last_match(1)}=[FILTERED]"
          else
            "#{Regexp.last_match(1)}://[FILTERED]@"
          end
        end
      end
    end

    def self.last_successful(kind)
      for_kind(kind).succeeded.order(:finished_at).last
    end

    def self.last_attempt(kind)
      for_kind(kind).order(:started_at).last
    end

    # Operator-facing snapshot: what succeeded, when, and whether it is stale.
    # Filtering by jitter is impossible; a failed attempt does NOT extend the
    # freshness window, because a week of failures must show up as stale data.
    def self.status_summary(now: Time.current)
      KINDS.each_with_object({}) do |kind, acc|
        success = last_successful(kind)
        attempt = last_attempt(kind)

        acc[kind.to_sym] = {
          last_success_at: success&.finished_at,
          last_attempt_at: attempt&.started_at,
          last_attempt: attempt && {
            status: attempt.status,
            trigger: attempt.trigger,
            counts: {
              fetched: attempt.fetched, created: attempt.created, updated: attempt.updated,
              skipped: attempt.skipped, rejected: attempt.rejected
            },
            error: attempt.last_error
          },
          running: for_kind(kind).running.exists?,
          stale: success.nil? || success.finished_at.nil? ||
                 success.finished_at < now - STALE_AFTER_SUCCESS
        }
      end
    end
  end
end
