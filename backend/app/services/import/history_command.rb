module Import
  # The operator-facing entry point for a controlled historical import from a
  # YAML manifest.
  #
  # Behaviour lives here rather than in a Rake task so it can be tested without
  # shelling out; `lib/tasks/import.rake` is a thin wrapper that prints `output`
  # and exits with `exit_status`.
  #
  # Argument validation happens BEFORE the runner runs. A missing manifest, an
  # invalid manifest path, or an absent season label is refused outright: the
  # season label is never inferred and must be given explicitly.
  #
  # Output is deliberately terse: a one-line summary, the entry errors an
  # operator needs to fix, and nothing else — no SQL, driver text, credentials
  # or traces.
  class HistoryCommand
    MAX_REPORTED_ERRORS = 10

    Result = Struct.new(:success, :output, :run_outcome, keyword_init: true) do
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

      manifest = Manifest.from_yaml(path.to_s)
      return manifest_failure(manifest) if manifest.invalid?

      outcome = run_runner(manifest)
      return failure_from(outcome) if outcome.failure?

      Result.new(
        success: true,
        output: success_output(outcome),
        run_outcome: outcome
      )
    end

    private

    def argument_error
      return 'a manifest path is required' if path.to_s.strip.empty?

      unless File.absolute_path?(path.to_s)
        return "the manifest path must be absolute (got #{path.inspect}); inside Docker the " \
               'repository data directory is mounted at /data'
      end

      return "manifest file not found or not a regular file: #{path}" unless File.file?(path.to_s)

      unless path.to_s.strip.end_with?('.yml', '.yaml')
        return "manifest path must end in .yml or .yaml (got #{path.inspect})"
      end

      return 'a season label is required, for example 2024/25' if season_label.strip.empty?

      unless season_label.strip.match?(ReferenceResolver::SEASON_LABEL_PATTERN)
        return "season label is not a recognised season: #{season_label.inspect} " \
               '(expected a form such as 2024/25)'
      end

      nil
    end

    def manifest_failure(manifest)
      lines = ["manifest is invalid: #{File.basename(path)}"]
      lines.concat(manifest.errors.map { |error| "  #{error}" })
      failure(lines.join("\n"))
    end

    def run_runner(manifest)
      HistoryRunner.new(manifest).call
    end

    def failure_from(outcome)
      reported = outcome.failures.first(MAX_REPORTED_ERRORS)
      lines = ["history import failed: #{File.basename(path)} (season #{season_label})"]
      lines.concat(reported.map { |failure| "  #{failure.entry.path}: #{failure.error}" })

      hidden = outcome.failures.length - reported.length
      lines << "  ... and #{hidden} more failures" if hidden.positive?

      if outcome.partial?
        lines << "partial: #{outcome.summary}"
      else
        lines << outcome.summary
      end

      failure(lines.join("\n"), outcome)
    end

    def success_output(outcome)
      [
        "history imported from #{File.basename(path)} (season #{season_label})",
        "  #{outcome.summary}",
      ].join("\n")
    end

    def failure(output, run_outcome = nil)
      Result.new(success: false, output: output, run_outcome: run_outcome)
    end
  end
end