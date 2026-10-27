module Import
  # Provider adapter for football-data.co.uk season CSVs.
  #
  # This is the *only* class that knows the provider's column names (`Div`,
  # `Date`, `Time`, `HomeTeam`, `AwayTeam`, `FTHG`, `FTAG`, `FTR`) and its date
  # format (dd/mm/yyyy). It converts raw string rows into normalized `MatchRow`
  # objects; it never touches the database. That separation is what lets a second
  # provider be added later without changing resolution or persistence.
  #
  # The source publishes no match identifier, so a stable provider key is composed
  # from the competition code, date, kickoff time and both team names. That key is
  # what the importer stores in `external_identifiers` to make imports idempotent.
  class FootballDataCoUkAdapter
    PROVIDER = "football_data".freeze

    # Columns the adapter needs. Passed to CsvReader so a file missing any of
    # them is rejected up front rather than producing silently wrong data.
    REQUIRED_COLUMNS = %w[Div Date Time HomeTeam AwayTeam FTHG FTAG FTR].freeze

    # football-data.co.uk writes dates as dd/mm/yyyy.
    DATE_FORMAT = "%d/%m/%Y".freeze

    # FTR is the full-time result from the home team's perspective. Any value here
    # means the match finished, so it maps to the `completed` status. Absent
    # results (pre-season fixtures published early) stay `scheduled`.
    COMPLETED_STATUS = "completed".freeze
    SCHEDULED_STATUS = "scheduled".freeze

    # Parses a single raw row into a `RowResult`.
    def self.parse(row, index: 0)
      new.parse(row, index: index)
    end

    # Parses every row, returning a `RowResult` per row in file order. A bad row
    # does not stop the others; the caller decides the failure policy.
    def self.parse_all(rows)
      rows.each_with_index.map { |row, index| parse(row, index: index) }
    end

    # Backwards-friendly alias used by specs that name the operation explicitly.
    def self.parse_row(row)
      result = parse(row)
      raise RowError, result.error unless result.success?

      result.row
    end

    # Raised by `parse_row` when a row cannot be normalized. The importer prefers
    # the non-raising `parse_all` so it can report every bad row at once.
    class RowError < StandardError; end

    def parse(row, index: 0)
      return RowResult.new(index: index, error: "empty row") if row.nil? || row.empty?

      error = validate(row)
      return RowResult.new(index: index, error: error) if error

      RowResult.new(index: index, row: build_row(row), error: nil)
    rescue ArgumentError, TypeError => e
      RowResult.new(index: index, error: e.message)
    end

    private

    def validate(row)
      return "home team name is missing" if blank?(row["HomeTeam"])
      return "away team name is missing" if blank?(row["AwayTeam"])

      # Date first: an unparseable date makes the row meaningless even if the
      # scores are fine, and the message is the most actionable to an operator.
      begin
        kickoff_at(row)
      rescue ArgumentError
        return "date/time is not a valid timestamp: #{row["Date"]} #{row["Time"]}".strip
      end

      score_error(row)
    end

    # Scores must be absent together, non-negative and integral when present.
    # Mirrors the matches table's check constraints so bad rows are rejected with
    # a row-level message rather than a database exception.
    def score_error(row)
      home = row["FTHG"]
      away = row["FTAG"]

      return nil if blank?(home) && blank?(away)
      return "only one score is present; both or neither are required" if blank?(home) || blank?(away)

      [home, away].each do |value|
        return "score is not a non-negative integer: #{value}" unless value.to_s.match?(/\A\d+\z/)
      end

      nil
    end

    def build_row(row)
      completed = !blank?(row["FTR"])

      MatchRow.new(
        provider: PROVIDER,
        provider_key: provider_key(row),
        competition_code: row["Div"].to_s.strip,
        season_label: nil, # supplied by the import run, not present in the file
        home_team_name: row["HomeTeam"].to_s.strip,
        away_team_name: row["AwayTeam"].to_s.strip,
        kickoff_at: kickoff_at(row),
        status: completed ? COMPLETED_STATUS : SCHEDULED_STATUS,
        home_score: completed ? Integer(row["FTHG"]) : nil,
        away_score: completed ? Integer(row["FTAG"]) : nil,
      )
    end

    def provider_key(row)
      [
        row["Div"].to_s.strip,
        row["Date"].to_s.strip,
        row["Time"].to_s.strip,
        row["HomeTeam"].to_s.strip,
        row["AwayTeam"].to_s.strip,
      ].join("|")
    end

    # Builds a UTC instant from the provider's dd/mm/yyyy date and HH:MM time.
    # Kickoffs are published in local UK time; this project stores UTC and applies
    # timezone handling at presentation, so the instant is interpreted as UTC here.
    def kickoff_at(row)
      date = Date.strptime(row["Date"].to_s.strip, DATE_FORMAT)
      hour, minute = parse_time(row["Time"])

      Time.utc(date.year, date.month, date.day, hour, minute)
    end

    def parse_time(value)
      text = value.to_s.strip
      return [0, 0] if text.empty?

      match = text.match(/\A(\d{1,2}):(\d{2})\z/)
      raise ArgumentError, "invalid time: #{text}" unless match

      [Integer(match[1]), Integer(match[2])]
    end

    def blank?(value)
      value.nil? || value.to_s.strip.empty?
    end
  end
end
