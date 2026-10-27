module Import
  # A provider-agnostic, already-normalized view of one fixture row.
  #
  # This is the contract between the provider adapters and the persistence layer.
  # Everything downstream works with these typed fields, never with raw CSV
  # strings, so a second provider only needs to produce the same object.
  #
  # `kickoff_at` is a UTC `Time`; `home_score`/`away_score` are Integers or nil
  # (nil means "no final result yet"); `status` is one of the values allowed by
  # the matches table's check constraint.
  #
  # Rows are frozen on construction. Once parsed, a row is a statement of what
  # the source said and must not be edited in place: downstream code would then
  # be comparing against a value nobody validated. An invalid row is a bug in the
  # adapter, so construction raises rather than letting a bad row travel.
  MatchRow = Struct.new(
    :provider,
    :provider_key,
    :competition_code,
    :season_label,
    :home_team_name,
    :away_team_name,
    :kickoff_at,
    :status,
    :home_score,
    :away_score,
    keyword_init: true,
  ) do
    MINIMAL_ATTRIBUTES = %i[provider provider_key competition_code home_team_name
                            away_team_name kickoff_at status].freeze

    # Accepts keyword arguments (as the adapter uses it) and a single Hash, so
    # specs and callers can build a row from a literal without changing shape.
    def initialize(attributes = nil, **kwargs)
      super(**(attributes.is_a?(Hash) ? attributes : {}), **kwargs)
      self.provider = provider.to_s.freeze if provider
      self.provider_key = provider_key.to_s.freeze if provider_key
      self.competition_code = competition_code.to_s.freeze if competition_code
      freeze
    end

    # Human-readable description used in error messages. Deliberately omits the
    # raw source row so logs never echo a whole line of provider data.
    def description
      "#{home_team_name} vs #{away_team_name}"
    end

    # Structural check used by the adapter's tests and by the importer before it
    # starts writing. Returns nil when the row is usable, or a message otherwise.
    def validation_error(statuses:)
      missing = MINIMAL_ATTRIBUTES.select { |attr| public_send(attr).nil? || public_send(attr).to_s.strip.empty? }
      return "missing #{missing.join(', ')}" if missing.any?
      return "unsupported status: #{status.inspect}" unless statuses.include?(status)
      return 'only one score is present' if home_score.nil? != away_score.nil?
      return 'a completed match needs both scores' if status == 'completed' && home_score.nil?

      nil
    end
  end
end
