module Import
  # The value object every import run returns. It is intentionally dumb: a plain,
  # immutable summary that callers, jobs and tests can assert on without knowing
  # anything about how the import was performed.
  #
  # Count semantics (fixed here so callers and tests never disagree):
  #   - `input`     — source rows read from the file, header excluded.
  #   - `processed` — rows that parsed cleanly and reached resolution.
  #   - `created`   — Match records newly persisted by this run.
  #   - `reused`    — rows matched to an already-persisted match; not re-created.
  #   - `rejected`  — rows that failed parsing or resolution and were not written.
  #
  # Invariants the importer must preserve:
  #   processed + rejected == input
  #   created + reused     == processed
  #
  # Error messages are deliberately plain strings. Persistence failures are
  # translated before they reach here so raw SQL, driver messages and stack
  # traces are never surfaced to callers.
  class Result
    attr_reader :input, :processed, :created, :reused, :rejected, :errors

    def initialize(success: false, input: 0, processed: 0, created: 0, reused: 0, rejected: 0, errors: [])
      @success = success
      @input = input
      @processed = processed
      @created = created
      @reused = reused
      @rejected = rejected
      @errors = Array(errors).freeze
      freeze
    end

    def success?
      @success
    end

    def failure?
      !@success
    end

    class << self
      # Builds a successful result. `rejected` defaults to zero because a success
      # run by definition wrote or reused every processed row.
      def success(input: 0, processed: 0, created: 0, reused: 0, rejected: 0, errors: [])
        new(
          success: true,
          input: input,
          processed: processed,
          created: created,
          reused: reused,
          rejected: rejected,
          errors: errors
        )
      end

      # Builds a failed result. Whole-batch atomicity means a failed run leaves
      # nothing persisted, so `created` and `reused` default to zero.
      def failure(input: 0, processed: 0, created: 0, reused: 0, rejected: 0, errors: [])
        new(
          success: false,
          input: input,
          processed: processed,
          created: created,
          reused: reused,
          rejected: rejected,
          errors: errors
        )
      end
    end
  end
end
