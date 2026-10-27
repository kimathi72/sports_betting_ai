# Runs one football-data.co.uk CSV import in the background.
#
# The job owns nothing but orchestration: it validates what can be validated
# cheaply, delegates to Import::MatchImporter (which already guarantees
# transactionality, idempotency and conflict handling), and reports the outcome.
# Duplicating any of that logic here would create a second, less-tested write
# path.
#
# Arguments are strings because they cross a process boundary through Redis. The
# path is untrusted input and must be inside an approved import directory; see
# Import::SourcePath.
#
# A FAILED IMPORT IS NOT A SUCCESSFUL JOB. `perform` returns the Import::Result so
# callers and logs can see the counts, but a rejected import raises
# `ImportFailed` after logging, which is what marks the job as failed in Sidekiq.
# Silently returning a failure would make a broken nightly import look healthy.
class ImportFootballDataJob < ApplicationJob
  queue_as :imports

  # Permanent: the input itself is wrong, so repeating it cannot help. Retrying
  # would burn worker capacity and delay the operator seeing the real problem.
  class ImportFailed < StandardError; end

  # Transient: the infrastructure failed, not the data. A retry can succeed, and
  # the importer is idempotent, so a retry that partially ran before failing is
  # safe to repeat.
  class TransientFailure < StandardError; end

  # Errors that mean "try again", never "fix the file". Database-connection loss,
  # deadlocks and lock timeouts are the realistic contenders for a long import
  # holding row locks while another run competes for the same mappings.
  TRANSIENT_ERRORS = [
    ActiveRecord::ConnectionNotEstablished,
    ActiveRecord::Deadlocked,
    ActiveRecord::LockWaitTimeout,
    ActiveRecord::StatementInvalid,
    PG::ConnectionBad,
    Redis::BaseConnectionError,
  ].freeze

  # Bounded: a transient problem that outlasts a handful of attempts is an
  # outage, and an operator should be told rather than the queue retried forever.
  MAX_RETRIES = 3
  RETRY_WAIT = 30 # seconds; Sidekiq applies its own backoff on top

  # RETRY OWNERSHIP. ActiveJob's `retry_on` and Sidekiq's own retry setting both
  # count attempts, so mixing them double-counts: with `attempts: 0` here, Sidekiq
  # still re-queued the wrapper once (observed as "Stopped retrying ... reoccurred
  # on 1 attempts" plus an entry in the retry set). This job therefore lets
  # ActiveJob decide *whether* a failure is retryable and lets Sidekiq bound *how
  # many* attempts happen, via `sidekiq_retry_in`:
  #
  #   - a permanent ImportFailed is never rescheduled (Sidekiq returns :discard)
  #   - a transient failure is retried, up to MAX_RETRIES total
  #   - anything else is an unexpected error and gets the bounded retry too, so a
  #     genuine outage is not thrown away, but it is never reported as success
  sidekiq_options retry: MAX_RETRIES

  # Transient failures are wrapped so the retry policy sees a single, stable class
  # while the original error is preserved as the cause for the log.
  rescue_from(*TRANSIENT_ERRORS) do |error|
    Rails.logger.warn("ImportFootballDataJob transient failure: #{error.class}: #{error.message}")
    raise TransientFailure, "transient failure, retrying: #{error.class}", cause: error
  end

  # Ask Sidekiq not to reschedule a permanent failure. Returning :discard from
  # `sidekiq_retry_in` is the supported way to stop retries for one exception
  # class without disabling them for the transient ones.
  sidekiq_retry_in do |_count, exception, _jobinst|
    exception.is_a?(ImportFailed) ? :discard : RETRY_WAIT
  end

  sidekiq_retries_exhausted do |msg, exception|
    Rails.logger.warn(
      "ImportFootballDataJob gave up after #{MAX_RETRIES} attempts: " \
      "#{exception.class}: #{exception.message}"
    )
  end

  # Runs the import and returns the result. The result is the job's value, but a
  # rejected import must not look successful to the queue, so `perform` raises
  # after recording the failure. Callers that want the result without failing
  # (specs, console work) use `run`, which never raises and never hides a failure.
  def perform(path, season_label)
    result = run(path, season_label)
    raise ImportFailed, failure_summary(result) if result.failure?

    result
  end

  # Performs the work and always returns an Import::Result, including for
  # argument problems. Never reports a failure as a success: every failure path
  # builds a failed Result with at least one actionable error.
  def run(path, season_label)
    source = validate_source(path)
    return record_failure(path, season_label, source) if source.failure?

    season = validate_season(season_label)
    return record_failure(path, season_label, season) if season.failure?

    result = Import::MatchImporter.new(path: source.record, season_label: season_label).call

    if result.failure?
      log_failure(source.record, season_label, result)
    else
      log_success(source.record, season_label, result)
    end

    result
  end

  private

  # Validation failures are real outcomes an operator must see, so they are
  # returned as a failed Import::Result (never raised): Sidekiq then records the
  # job as failed through `after_perform` below.
  def validate_source(path)
    Import::SourcePath.validate!(path)
    Outcome.success(path)
  rescue Import::SourcePath::NotPermitted => e
    Outcome.failure(e.message)
  end

  def validate_season(season_label)
    return Outcome.success(season_label) if season_label.to_s.strip.match?(Import::ReferenceResolver::SEASON_LABEL_PATTERN)

    Outcome.failure('a recognised season label is required, for example 2024/25')
  end

  def record_failure(path, season_label, outcome)
    result = Import::Result.failure(
      input: 1,
      rejected: 1,
      errors: [Import::Result.error(index: 0, message: outcome.error)]
    )

    Rails.logger.warn(
      "ImportFootballDataJob failed file=#{File.basename(path.to_s)}" \
      " season=#{season_label} reason=#{outcome.error}"
    )

    result
  end

  # Tiny internal result for the cheap pre-checks, so they compose the same way
  # as Import::SourcePath's exception-based contract.
  Outcome = Struct.new(:record, :error, keyword_init: true) do
    def success?
      error.nil?
    end

    def failure?
      !success?
    end

    def self.success(record)
      new(record: record)
    end

    def self.failure(error)
      new(error: error)
    end
  end

  # One structured line per run: enough to correlate with the enqueuing command
  # without dumping file contents or any credential.
  def log_success(source, season_label, result)
    Rails.logger.info(
      "ImportFootballDataJob ok file=#{File.basename(source)} season=#{season_label} " \
      "#{result.summary}"
    )
  end

  def log_failure(source, season_label, result)
    Rails.logger.warn(
      "ImportFootballDataJob failed file=#{File.basename(source)} season=#{season_label} " \
      "reason=#{failure_summary(result)}"
    )
  end

  # Only the first error is logged: a 400-row broken file would otherwise fill
  # the log with near-identical lines.
  def failure_summary(result)
    first = result.errors.first
    first ? Import::Result.format_error(first) : 'no rows could be imported'
  end
end
