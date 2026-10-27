require 'yaml'

module Import
  # A validated, immutable list of historical files to import.
  #
  # The manifest is the operator's explicit statement of intent: which file, under
  # which season, for which competition. It is validated as a whole before
  # anything is enqueued, so a typo is a rejected manifest rather than a partially
  # imported history.
  #
  # Two rules matter more than the rest:
  #
  #   - every entry names its own season label; it is never inferred from fixture
  #     dates, because a boundary fixture would silently land in the wrong season;
  #   - duplicates are rejected, not deduplicated. "The same season twice for one
  #     competition" or "the same file twice" is a contradiction, and guessing
  #     which entry the operator meant risks importing the wrong history.
  #
  # Paths go through Import::SourcePath, so a manifest cannot point the importer
  # at arbitrary files.
  class Manifest
    Entry = Struct.new(:path, :season_label, :competition_code, :provider, keyword_init: true) do
      def initialize(**kwargs)
        super
        freeze
      end
    end

    # YAML keys that are accepted, so a typo like `compitition:` is reported rather
    # than silently ignored.
    ALLOWED_KEYS = %w[path season competition provider].freeze

    attr_reader :entries, :errors

    def self.from_yaml(path)
      unless File.file?(path.to_s)
        return new(entries: [], errors: ["manifest not found: #{File.basename(path.to_s)}"])
      end

      parsed = YAML.safe_load(File.read(path), permitted_classes: [], aliases: false)
      unless parsed.is_a?(Array)
        return new(entries: [], errors: ['manifest must be a YAML list of entries'])
      end

      new(entries: parsed)
    rescue Psych::Exception => e
      new(entries: [], errors: ["manifest YAML could not be parsed: #{e.class}"])
    end

    def initialize(entries:, errors: nil)
      @errors = Array(errors)
      @entries = build_entries(Array(entries))
      # An empty manifest is never a valid intent: "import nothing" is either a
      # mistake in the file or a mistake at the call site.
      @errors << 'manifest contains no entries' if @entries.empty? && @errors.empty?
      freeze
    end

    def valid?
      errors.empty?
    end

    def invalid?
      !valid?
    end

    # Human-readable failures, one per problem, for a CLI to print.
    def error_message
      errors.join("\n")
    end

    private

    def build_entries(raw)
      built = raw.each_with_index.map { |entry, index| build_entry(entry, index) }
      built.compact.tap { |entries| @errors.concat(duplicate_errors(entries)) }
    end

    def build_entry(raw, index)
      unless raw.is_a?(Hash)
        @errors << "entry #{index + 1}: each manifest entry must be a mapping"
        return nil
      end

      entry = raw.to_h { |key, value| [key.to_s, value] }
      unknown = entry.keys - ALLOWED_KEYS
      if unknown.any?
        @errors << "entry #{index + 1}: unknown key(s) #{unknown.join(', ')}"
        return nil
      end

      season = entry['season'].to_s.strip
      competition = entry['competition'].to_s.strip
      # Only one provider exists today, so omitting it means football-data.co.uk.
      # Naming an unsupported one is still an error, never a silent fallback.
      provider = entry['provider'].to_s.strip
      provider = FootballDataCoUkAdapter::PROVIDER if provider.empty?

      return reject(index, 'season label is missing') if season.empty?
      unless season.match?(ReferenceResolver::SEASON_LABEL_PATTERN)
        return reject(index, "season label is not recognised: #{season.inspect}")
      end

      return reject(index, 'competition code is missing') if competition.empty?
      unless ReferenceResolver::KNOWN_PROVIDERS.include?(provider)
        return reject(index, "provider is not supported: #{provider.inspect}")
      end

      path = resolve_path(entry['path'], index)
      return nil if path.nil?

      Entry.new(path: path, season_label: season,
                competition_code: competition.upcase, provider: provider)
    end

    def resolve_path(raw, index)
      if raw.to_s.strip.empty?
        @errors << "entry #{index + 1}: path is missing"
        return nil
      end

      Import::SourcePath.validate!(raw)
    rescue Import::SourcePath::NotPermitted => e
      @errors << "entry #{index + 1}: #{e.message}"
      nil
    end

    def reject(index, message)
      @errors << "entry #{index + 1}: #{message}"
      nil
    end

    def duplicate_errors(entries)
      errors = []

      entries.group_by { |entry| [entry.competition_code, entry.season_label] }
             .each do |(competition, season), group|
        next if group.length < 2

        errors << "duplicate entry: season #{season} for competition #{competition} " \
                  'appears more than once'
      end

      entries.group_by(&:path).each do |path, group|
        next if group.length < 2

        errors << "duplicate entry: the same file #{File.basename(path)} is listed more than once"
      end

      errors
    end
  end
end
