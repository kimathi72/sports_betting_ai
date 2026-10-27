module Import
  # The value object every import run returns: an immutable summary callers,
  # jobs and CLI tasks can assert on without knowing how the import was done.
  #
  # COUNTER SEMANTICS. Every source row lands in exactly one row-outcome counter,
  # which is what keeps the totals honest:
  #
  #   - `input`     — data rows the reader produced (header excluded, blank lines
  #                   already dropped). The denominator for every invariant.
  #   - `processed` — rows validated, resolved and persisted. Always equal to
  #                   `created + updated + skipped`; it is never passed in.
  #   - `created`   — rows persisted as a NEW Match.
  #   - `updated`   — rows that CHANGED an existing Match (e.g. a scheduled fixture
  #                   receiving its first result).
  #   - `skipped`   — rows that matched an existing Match and changed nothing
  #                   (e.g. re-importing an identical completed result).
  #   - `rejected`  — rows that failed validation, resolution or persistence.
  #
  # `skipped` is deliberately not called `reused`. Reusing a canonical Team or
  # Competition happens *inside* a row that still created, updated or skipped a
  # Match; "this record was reused" and "this row was skipped" are different
  # concepts and must never share a counter.
  #
  # ENFORCED INVARIANTS (checked by the constructor, not just documented):
  #   - counters are non-negative integers;
  #   - created + updated + skipped + rejected == input;
  #   - processed == created + updated + skipped;
  #   - a successful result has rejected == 0;
  #   - a failed result rejected at least one row and wrote nothing.
  #
  # A failed run rolls the whole batch back, so claiming created/updated/skipped
  # rows on a failure would report writes that never happened. That is rejected
  # here rather than left to the caller to get right.
  #
  # Errors are structured (see `.error`) so a caller can map a failure to the row
  # that caused it. Messages are plain text; SQL, driver messages, credentials and
  # stack traces are translated away before reaching this object.
  class Result
    # Raised when a caller supplies counters that cannot describe a real run.
    # Deliberately a programming-error signal, not an import outcome.
    class InvalidCounters < StandardError; end

    COUNTERS = %i[input created updated skipped rejected].freeze

    # Builds the canonical error entry. `index` is the zero-based position of the
    # offending data row; `row` is the one-based number an operator sees in a
    # spreadsheet. Keeping both means callers never re-derive the offset.
    def self.error(index:, message:)
      { index: Integer(index), row: Integer(index) + 1, message: message.to_s }.freeze
    end

    # Renders an error entry as the operator-facing "row N: reason" line.
    # Accepts a hash from `.error` or a bare string, so it is safe to use on
    # legacy callers while the stricter shape is adopted.
    def self.format_error(error)
      return error.to_s unless error.is_a?(Hash)

      row = error[:row] || (error[:index] ? Integer(error[:index]) + 1 : nil)
      row ? "row #{row}: #{error[:message]}" : error[:message].to_s
    end

    attr_reader :input, :created, :updated, :skipped, :rejected, :errors

    def initialize(success: false, input: 0, created: 0, updated: 0, skipped: 0,
                   rejected: 0, errors: [], processed: nil)
      @success = success
      @input = input
      @created = created
      @updated = updated
      @skipped = skipped
      @rejected = rejected
      @processed = processed.nil? ? created + updated + skipped : processed
      @errors = normalize_errors(errors)
      validate_counters!
      freeze
    end

    # Rows that reached persistence. Derived, never supplied by callers, so it
    # cannot drift from the row outcomes.
    def processed
      @processed
    end

    def success?
      @success
    end

    def failure?
      !@success
    end

    def failure_errors
      errors
    end

    # Concise operator-facing one-liner for logs and the CLI task.
    def summary
      prefix = success? ? 'imported' : 'import failed,'
      "#{prefix} #{input} rows: #{created} created, #{updated} updated, " \
        "#{skipped} skipped, #{rejected} rejected"
    end

    class << self
      # Builds a successful result. A successful run, by definition, rejected
      # no rows.
      #
      # `processed:` is accepted so the constructor can reject a caller that
      # supplies a count inconsistent with the row outcomes; normal callers omit
      # it and let it be derived.
      def success(input: 0, created: 0, updated: 0, skipped: 0, rejected: 0, errors: [],
                  processed: nil)
        new(
          success: true,
          input: input,
          created: created,
          updated: updated,
          skipped: skipped,
          rejected: rejected,
          errors: errors,
          processed: processed
        )
      end

      # Builds a failed result. Whole-batch atomicity means a failed run leaves
      # nothing persisted, so created/updated/skipped must be zero.
      def failure(input: 0, created: 0, updated: 0, skipped: 0, rejected: 0, errors: [],
                  processed: nil)
        new(
          success: false,
          input: input,
          created: created,
          updated: updated,
          skipped: skipped,
          rejected: rejected,
          errors: errors,
          processed: processed
        )
      end
    end

    private

    def normalize_errors(errors)
      Array(errors).map do |error|
        case error
        when Hash then error.freeze
        else { message: error.to_s }.freeze
        end
      end.freeze
    end

    def validate_counters!
      COUNTERS.each do |counter|
        value = public_send(counter)
        next if value.is_a?(Integer) && value >= 0

        raise InvalidCounters, "#{counter} must be a non-negative integer (got #{value.inspect})"
      end

      outcomes = created + updated + skipped + rejected
      if outcomes != input
        raise InvalidCounters,
              "created + updated + skipped + rejected (#{outcomes}) must account for " \
              "every input row (#{input})"
      end

      row_outcomes = created + updated + skipped
      unless processed == row_outcomes
        raise InvalidCounters,
              "processed (#{processed}) must equal created + updated + skipped (#{row_outcomes})"
      end

      if success? && rejected.positive?
        raise InvalidCounters,
              'a successful result cannot report rejected rows; a batch with a rejected ' \
              'row is rolled back and must be reported as a failure'
      end

      # An empty run (zero input rows) is a valid state, not a failure with
      # missing detail: an empty file legitimately rejects nothing.
      return if success? || input.zero?

      if rejected.zero?
        raise InvalidCounters, 'a failed result must report at least one rejected row'
      end

      return if row_outcomes.zero?

      raise InvalidCounters,
            'a failed result is rolled back, so created, updated and skipped must all be zero '
            "(got #{created}, #{updated}, #{skipped})"
    end
  end
end
