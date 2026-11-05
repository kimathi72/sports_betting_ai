# Shared behaviour for the two daily synchronization jobs.
#
# The job layer is deliberately THIN. Everything that decides *what* a
# synchronization does (season selection, download, import, counting, failure
# classification) lives in Sync::BaseSynchronizer and is covered by
# spec/services/sync/. This module only answers three questions the synchronizer
# must not answer for itself, because each one is a property of running under
# Sidekiq rather than of the import:
#
#   1. Should this attempt happen at all?     -> `already_running?`
#   2. Does a finished run count as success?  -> `raise_unless_successful!`
#   3. If not, is it retried or discarded?    -> `sidekiq_retry_in`
#
# OVERLAP IS NOT A FAILURE. If yesterday's result import is still running when
# today's is dequeued, the correct outcome is "skipped", not a red job. Raising
# would fill the retry set with attempts that can only ever overlap again.
#
# A FAILED RUN MUST FAIL THE JOB. The synchronizer returns a failed SyncRun rather
# than raising, so that the ledger always records the attempt. Unless the job then
# raises, Sidekiq would mark the attempt successful and an operator watching the
# queue would see nothing wrong while the data goes stale.
module ScheduledSynchronization
  extend ActiveSupport::Concern

  # Bounded: a provider outage lasting longer than a few attempts is an outage,
  # and a daily job that keeps retrying into the next day competes with the next
  # scheduled run instead of helping.
  MAX_RETRIES = 3

  # Backoff of 60s, 300s, 1500s. Deliberately well inside the daily interval, so a
  # transient failure is retried long before the next scheduled attempt, and well
  # above the provider's rate-limit window.
  RETRY_WAITS = [1.minute, 5.minutes, 25.minutes].freeze

  # Transient failures are worth repeating: the provider was unreachable, or the
  # file arrived half-written. The importer is idempotent and transactional, so a
  # retry cannot duplicate or corrupt what a partial attempt wrote.
  TRANSIENT_ERRORS = [
    Sync::BaseSynchronizer::TransientError,
    Import::CsvDownloader::TransientError,
    Net::OpenTimeout,
    Net::ReadTimeout,
    IOError,
    ActiveRecord::ConnectionNotEstablished,
    ActiveRecord::Deadlocked,
  ].freeze

  # Raised after a run finished in the ledger with status `failed`, so the queue
  # records a genuine failure while the ledger keeps the classified detail.
  class SynchronizationFailed < StandardError; end

  included do
    queue_as :sync

    sidekiq_options retry: MAX_RETRIES

    # A permanent failure cannot be fixed by repeating it: the season does not
    # exist at the provider, the configuration is wrong, or the URL is refused.
    # Discarding immediately is what stops a retry storm against a rate-limited
    # source, and lets the ledger's error reach an operator sooner.
    # Sidekiq 7 stores the policy as a block, so the decision itself lives in a
    # class method that both this block and the specs can call directly.
    sidekiq_retry_in do |count, exception, _job_instance|
      retry_wait_for(count, exception)
    end

    sidekiq_retries_exhausted do |msg, exception|
      Rails.logger.error(
        "[sync] #{msg["class"]} gave up after #{MAX_RETRIES} attempts: " \
        "#{exception.class}: #{exception.message}"
      )
    end
  end

  # Exceptions that must never be retried: the provider will answer the same way
  # however many times we ask, and a weekly CSV source is rate-limited.
  NON_RETRYABLE = [
    Sync::BaseSynchronizer::PermanentError,
    Sync::BaseSynchronizer::ConfigurationError,
    Import::CsvDownloader::Unavailable,
    Import::CsvDownloader::InvalidContent,
    Import::CsvDownloader::InvalidInput,
  ].freeze

  class_methods do
    # Returns :discard for a permanent failure, or the number of seconds to wait
    # before the next attempt for anything that might succeed later.
    #
    # Retrying an unexpected error is deliberate: a genuine infrastructure outage
    # surfaces as an ordinary StandardError, and discarding it would leave the
    # ledger failed until an operator noticed. It is bounded by MAX_RETRIES.
    def retry_wait_for(count, exception)
      return :discard if NON_RETRYABLE.any? { |klass| exception.is_a?(klass) }

      RETRY_WAITS.fetch(count) { RETRY_WAITS.last * (2**count) }
    end
  end

  # Runs one synchronization and returns the ledger row.
  #
  # `trigger` records why this attempt happened. A manual invocation (a rake task
  # or a console call) must be distinguishable from a scheduled one when an
  # operator later asks "who ran this at 14:20?".
  def perform(trigger = "schedule")
    run = synchronizer.call(trigger: trigger.to_s)
    log_outcome(run)
    raise_unless_successful!(run)
    run
  rescue Sync::SyncRun::AlreadyRunning => e
    # The designed outcome of two overlapping schedules. Logged at INFO, because
    # an operator debugging "why did nothing run?" needs to see that something
    # did, and that it correctly refused.
    Rails.logger.info("[sync:#{log_kind}] skipped: #{e.message}")
    nil
  end

  private

  def synchronizer_class
    raise NotImplementedError, "#{self.class} must define synchronizer_class"
  end

  def synchronizer
    synchronizer_class.new
  end

  def log_kind
    synchronizer_class::KIND
  end

  # One structured line per run. Counts only: the ledger holds the detail, and a
  # log line must never carry a provider URL with an embedded credential.
  def log_outcome(run)
    if run.nil?
      Rails.logger.info("[sync:#{log_kind}] no run recorded")
    elsif run.succeeded?
      Rails.logger.info(
        "[sync:#{log_kind}] succeeded in #{run.duration_seconds&.round(1)}s: " \
        "fetched=#{run.fetched} created=#{run.created} updated=#{run.updated} " \
        "skipped=#{run.skipped} rejected=#{run.rejected}"
      )
    else
      Rails.logger.error(
        "[sync:#{log_kind}] failed after #{run.duration_seconds&.round(1)}s: #{run.last_error}"
      )
    end
  end

  def raise_unless_successful!(run)
    return if run.nil? || run.succeeded?

    raise SynchronizationFailed,
          "#{log_kind} synchronization failed: #{run.last_error || "no detail recorded"}"
  end
end
