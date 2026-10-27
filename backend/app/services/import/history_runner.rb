module Import
  # Orchestrates multi-season historical imports from a validated manifest.
  #
  # A multi-file history import is NOT globally atomic, and pretending otherwise
  # would be a lie an operator could act on. Each file is imported through the
  # single-file importer, which is transactional on its own; if file 3 of 5
  # fails, files 1-2 stay imported. What the runner must guarantee instead:
  #
  #   - every entry carries its own season, so files cannot bleed into one another
  #   - one failure does not abort the remaining entries silently: the outcome says
  #     exactly which succeeded and which did not
  #   - re-running the whole manifest is safe, because each file import is idempotent
  #   - entries are processed in manifest order, never concurrently, because
  #     concurrent imports compete for the same mapping rows
  #
  # The runner owns no import logic. It delegates every file to
  # Import::MatchImporter, which already guarantees transactionality,
  # idempotency, conflict protection and reference resolution. Adding parsing
  # or persistence here would create a second, less-tested write path.
  class HistoryRunner
    # Sequential execution is a deliberate choice: concurrent imports contend
    # for the same mapping rows. This constant guards against someone
    # "speeding it up" by parallelising.
    CONCURRENCY = 1

    # A single manifest entry that failed. Carries the entry so the operator
    # can find the file, and the error so they can fix it.
    class EntryFailure
      attr_reader :entry, :error

      def initialize(entry:, error:)
        @entry = entry
        @error = error
      end
    end

    # The outcome of a whole manifest run.
    class RunOutcome
      def initialize(success:, results:, failures:, total_created:, total_skipped:,
                     summary: nil)
        @success = success
        @results = results
        @failures = failures
        @total_created = total_created
        @total_skipped = total_skipped
        @summary = summary
      end

      def success?
        @success
      end

      def failure?
        !@success
      end

      def partial?
        !@success && @results.any?(&:success?)
      end

      attr_reader :results, :failures, :total_created, :total_skipped

      def summary
        @summary || build_summary
      end

      private

      def build_summary
        total = @results.length
        succeeded = total - @failures.length
        failed = @failures.length

        if total.zero?
          'no files to import'
        elsif @failures.empty?
          "#{total} file#{'s' if total != 1} imported"
        else
          "#{succeeded} of #{total} files imported, #{failed} failed"
        end
      end
    end

    def initialize(manifest)
      @manifest = manifest
    end

    def call
      unless @manifest.valid?
        return RunOutcome.new(
          success: false,
          results: [],
          failures: [],
          total_created: 0,
          total_skipped: 0,
          summary: "manifest is invalid: #{@manifest.error_message}"
        )
      end

      results = []
      failures = []
      total_created = 0
      total_skipped = 0

      @manifest.entries.each do |entry|
        result = import_entry(entry)

        results << result
        if result.success?
          total_created += result.created
          total_skipped += result.skipped
        else
          failures << EntryFailure.new(
            entry: entry,
            error: Import::Result.format_error(result.errors.first)
          )
        end
      end

      RunOutcome.new(
        success: failures.empty?,
        results: results,
        failures: failures,
        total_created: total_created,
        total_skipped: total_skipped
      )
    end

    private

    # Delegates to the established single-file importer. The importer owns
    # parsing, reference resolution, the batch transaction and idempotency;
    # this method adds nothing but the loop.
    def import_entry(entry)
      importer = MatchImporter.new(path: entry.path, season_label: entry.season_label)
      importer.call
    end
  end
end