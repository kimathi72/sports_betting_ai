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
    keyword_init: true
  ) do
    # Human-readable description used in error messages. Deliberately omits the
    # raw source row so logs never echo a whole line of provider data.
    def description
      "#{home_team_name} vs #{away_team_name}"
    end
  end
end
