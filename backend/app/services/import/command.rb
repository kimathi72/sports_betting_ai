module Import
  # The operator-facing entry point for a single manual CSV import.
  #
  # Behaviour lives here rather than in a Rake task so it can be tested without
  # shelling out; `lib/tasks/import.rake` is a thin wrapper that prints `output`
  # and exits with `exit_status`.
  #
  # Argument validation happens BEFORE the importer runs. A missing file, a
  # relative path or an absent season label is refused outright: guessing any of
  # them would import data under an identity nobody chose, and the season label in
  # particular is never inferred from the file.
  #
  # Output is deliberately terse: a one-line summary, the row errors an operator
  # needs to fix, and nothing else — no SQL, driver text, credentials or traces.
  class Command
    # Printing every error from a large broken file would bury the useful ones.
    MAX_REPORTED_ERRORS = 10

    Result = Struct.new(:success, :output, :import_result, keyword_init: true) do
      def success?
        success
      end

      def failure?
        !success?
      end

      def exit_status
        success ? 0 : 1
      end
    end

    def initialize(path:, season_label:)
      @path = path
      @season_label = season_label.to_s
    end

    attr_reader :path, :season_label

    def call
      invalid = argument_error
      return failure(invalid) if invalid

      outcome = run_import
      return failure_from(outcome) if outcome.failure?

      Result.new(
        success: true,
        output: success_output(outcome),
        import_result: outcome
      )
    end

    private

    def argument_error
      return 'a file path is required' if path.to_s.strip.empty?

      unless File.absolute_path?(path.to_s)
        return "the file path must be absolute (got #{path.inspect}); inside Docker the " \
               'repository data directory is mounted at /data'
      end

      return "file not found or not a regular file: #{path}" unless File.file?(path.to_s)
      return 'a season label is required, for example 2024/25' if season_label.strip.empty?

      unless season_label.strip.match?(ReferenceResolver::SEASON_LABEL_PATTERN)
        return "season label is not a recognised season: #{season_label.inspect} " \
               '(expected a form such as 2024/25)'
      end

      nil
    end

    def run_import
      MatchImporter.new(path: path, season_label: season_label).call
    end

    def failure_from(import_result)
      reported = import_result.errors.first(MAX_REPORTED_ERRORS)
      lines = ["import failed: #{File.basename(path)} (season #{season_label})"]
      lines.concat(reported.map { |error| "  #{Import::Result.format_error(error)}" })

      hidden = import_result.errors.length - reported.length
      lines << "  ... and #{hidden} more errors" if hidden.positive?

      failure(lines.join("\n"), import_result)
    end

    def success_output(import_result)
      [
        "imported #{File.basename(path)} (season #{season_label})",
        "  #{import_result.summary}",
      ].join("\n")
    end

    def failure(output, import_result = nil)
      Result.new(success: false, output: output, import_result: import_result)
    end
  end
end
