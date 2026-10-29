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
    REQUIRED_COLUMNS = %w[Div Date HomeTeam AwayTeam FTHG FTAG FTR].freeze

    # Present in modern files, absent from older ones. Rejecting the older files
    # would make real history unreachable; inventing a kickoff for them would
    # fabricate data, so the row records `time_known: false` instead.
    OPTIONAL_COLUMNS = %w[Time].freeze

    # When a file has no Time column, fixtures are anchored at this UTC hour.
    # Midday is used deliberately: midnight would sit exactly on the date
    # boundary, so a timezone conversion at presentation could shift a fixture
    # into the previous day. Flagging the row via `time_known` keeps the
    # placeholder from being mistaken for a real kickoff.
    UNDATED_TIME_HOUR = 12

    # football-data.co.uk writes dates as dd/mm/yyyy.
    DATE_FORMAT = "%d/%m/%Y".freeze

    # A strict four-digit year. `Date.strptime('%d/%m/%Y')` would happily read
    # "16/08/24" as the year 24 AD, which is almost never what an operator meant,
    # so the shape is checked before strptime sees it.
    DATE_PATTERN = %r{\A(\d{1,2})/(\d{1,2})/(\d{4})\z}.freeze

    # The 2016/17 file is the one season that writes dates as dd/mm/yy. Kept as a
    # separate, narrower pattern so the two-digit form can never be confused with
    # the four-digit one, and expanded explicitly rather than by strptime.
    TWO_DIGIT_YEAR_PATTERN = %r{\A(\d{1,2})/(\d{1,2})/(\d{2})\z}.freeze

    # The first season the platform supports (2016/17). Used ONLY as a sanity
    # floor for TWO-DIGIT year expansion: an expanded year before this is far more
    # likely to be a misread than real data. It deliberately does NOT restrict
    # explicit four-digit years — the source's older files legitimately contain
    # dates such as 08/08/2015.
    EARLIEST_SEASON_YEAR = 2016

    # FTR is the full-time result from the home team's perspective. It is the
    # single field that says whether a row asserts a finished result. The policy:
    #
    #   H / D / A — a completed match; BOTH scores are required and must be valid.
    #   P         — postponed; no result, so scores must be absent.
    #   blank     — scheduled, but ONLY when both scores are absent. A blank FTR
    #               beside a score means the export disagrees with itself; that is
    #               rejected rather than silently discarding the score.
    #   anything  — unknown; rejected. A new code needs a deliberate mapping.
    #
    # Codes are case-sensitive: a lowercase "h" is a provider change that should
    # be reviewed, not guessed at.
    COMPLETED_STATUS = "completed".freeze
    SCHEDULED_STATUS = "scheduled".freeze
    POSTPONED_STATUS = "postponed".freeze
    COMPLETED_CODES = %w[H D A].freeze
    POSTPONED_CODES = %w[P].freeze
    STATUS_BY_CODE = (COMPLETED_CODES.index_with { COMPLETED_STATUS }
                                      .merge(POSTPONED_CODES.index_with { POSTPONED_STATUS })).freeze

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

    # Checks run cheapest-and-most-actionable first: identity, then the date,
    # then the result policy. An unparseable date makes a row meaningless even if
    # its scores are fine, so the date message reaches the operator first.
    def validate(row)
      return "competition code (Div) is missing" if blank?(row["Div"])
      return "home team name is missing" if blank?(row["HomeTeam"])
      return "away team name is missing" if blank?(row["AwayTeam"])

      date_error = timestamp_error(row)
      return date_error if date_error

      result_error(row)
    end

    # The date is required. The time is required only when the file publishes a
    # Time column at all: seasons before 2019/20 do not, and the source's silence
    # is not the same as a malformed value.
    def timestamp_error(row)
      date = parse_date(row["Date"])
      return "date is missing" if date.nil?
      return "date is not a valid dd/mm/yyyy date: #{row["Date"]}" if date == :invalid

      return nil unless row.key?("Time")

      time = parse_time(row["Time"])
      return "kickoff time (Time) is missing" if time.nil?
      return "kickoff time is not a valid HH:MM time: #{row["Time"]}" if time == :invalid

      nil
    end

    # The FTR policy. Every branch is deliberate; see COMPLETED_CODES above.
    # This mirrors the matches table's check constraints so a bad row is rejected
    # with a row-level message instead of a database exception.
    def result_error(row)
      code = row["FTR"].to_s.strip
      home = row["FTHG"]
      away = row["FTAG"]
      has_scores = !(blank?(home) && blank?(away))

      if code.empty?
        # No outcome asserted. Scores beside a blank FTR are contradictory data.
        return "FTR is blank but a score is present; a finished result needs a " \
               "full-time result code (H, D or A)" if has_scores
        return nil
      end

      unless STATUS_BY_CODE.key?(code)
        return "unknown full-time result code (FTR): #{code}"
      end

      return nil if STATUS_BY_CODE.fetch(code) == POSTPONED_STATUS && !has_scores
      if STATUS_BY_CODE.fetch(code) == POSTPONED_STATUS
        return "FTR shows a postponed match (#{code}) but scores are present"
      end

      return "a completed match (FTR=#{code}) must carry both scores" unless has_scores
      return "only one score is present; both or neither are required" if blank?(home) || blank?(away)

      [home, away].each do |value|
        return "score is not a non-negative integer: #{value}" unless score?(value)
      end

      nil
    end

    def build_row(row)
      status = STATUS_BY_CODE.fetch(row["FTR"].to_s.strip, SCHEDULED_STATUS)
      completed = status == COMPLETED_STATUS

      MatchRow.new(
        provider: PROVIDER,
        provider_key: provider_key(row),
        competition_code: normalize_text(row["Div"]),
        season_label: nil, # supplied by the import run, not present in the file
        # Display names are kept as the source spells them, trimmed only. The
        # canonical identity is `Team.normalize`d, which is the resolver's job.
        home_team_name: row["HomeTeam"].to_s.strip,
        away_team_name: row["AwayTeam"].to_s.strip,
        kickoff_at: kickoff_at(row),
        status: status,
        home_score: completed ? Integer(row["FTHG"]) : nil,
        away_score: completed ? Integer(row["FTAG"]) : nil,
        time_known: time_known?(row)
      )
    end

    # Whether the source actually published a kickoff time for this row. False
    # for older seasons, where `kickoff_at` carries a documented placeholder.
    def time_known?(row)
      !parse_time(row["Time"]).nil?
    rescue Date::Error
      false
    end

    # The provider publishes no match id, so this key IS the match identity and
    # must be stable across harmless formatting differences. Each component is
    # normalised (case, internal whitespace) and the date/time are rendered from
    # their parsed values, so "9:05" and "09:05" or "1/1/2025" and "01/01/2025"
    # cannot produce two identities for one fixture. Team names use the same
    # policy as the canonical Team identity (`Team.normalize`), so the key and the
    # resolved teams agree about what counts as the same name.
    #
    # Empty components are never allowed to collapse: validation has already
    # rejected blank Div and team names, so a key always has five real parts.
    def provider_key(row)
      kickoff = kickoff_at(row)

      [
        normalize_text(row["Div"]),
        kickoff.strftime("%Y-%m-%d"),
        # When no time was published, the key must NOT embed the placeholder: a
        # later file that adds kickoff times would otherwise look like a
        # different fixture and duplicate the match. An empty segment keeps the
        # identity "this fixture on this date" stable across both file shapes.
        time_known?(row) ? kickoff.strftime("%H:%M") : "",
        Team.normalize(row["HomeTeam"]),
        Team.normalize(row["AwayTeam"]),
      ].join("|")
    end

    # Builds a UTC instant from the provider's dd/mm/yyyy date and HH:MM time.
    # Kickoffs are published in local UK time; this project stores UTC and applies
    # timezone handling at presentation, so the instant is interpreted as UTC here.
    def kickoff_at(row)
      date = parse_date(row["Date"])
      hour, minute = parse_time(row["Time"]) || [UNDATED_TIME_HOUR, 0]

      Time.utc(date.year, date.month, date.day, hour, minute)
    end

    # Returns a Date, nil when absent, or :invalid when the text is not a
    # dd/mm/yyyy date. Both `dd/mm/yyyy` and the one historical season's
    # `dd/mm/yy` are accepted; see TWO_DIGIT_YEAR_PATTERN for why a two-digit
    # year is expanded explicitly rather than handed to strptime.
    def parse_date(value)
      text = value.to_s.strip
      return nil if text.empty?

      if text.match?(DATE_PATTERN)
        parse_date_parts(text)
      elsif (match = text.match(TWO_DIGIT_YEAR_PATTERN))
        # `\d{4}\z` above already claimed four-digit years, so this branch is the
        # two-digit case only. The 2000s expansion is a rule, not a guess.
        parse_date_parts(text, year: expand_two_digit_year(match[3].to_i))
      else
        :invalid
      end
    end

    # Parses dd/mm/yyyy. The `year:` argument is only supplied by the two-digit
    # path, which has already expanded the year; an explicit four-digit year is
    # taken at face value.
    #
    # Day-first order is the source's documented format and is enforced here:
    # "04/05/2016" is 4 May, never 5 April.
    def parse_date_parts(text, year: nil)
      if year
        day, month = text.split('/').map { |part| Integer(part, 10) }
        return :invalid unless Date.valid_date?(year, month, day)

        # The floor applies ONLY to an expanded two-digit year. It exists to catch
        # a wrong expansion ("13/08/15" -> 2015), not to limit which seasons the
        # platform may hold: a file written as 08/08/2015 is real history and must
        # be accepted.
        return :invalid if year < EARLIEST_SEASON_YEAR

        Date.new(year, month, day)
      else
        Date.strptime(text, DATE_FORMAT)
      end
    rescue Date::Error, ArgumentError
      :invalid
    end

    # Two-digit years are interpreted as 20xx. The platform's first supported
    # season is 2016/17 and every season since is in the 2000s, so 16 means 2016
    # — but the result is validated against EARLIEST_SEASON_YEAR afterwards, so
    # an implausible value is rejected rather than guessed into the corpus.
    def expand_two_digit_year(two_digits)
      2000 + two_digits
    end

    # Returns [hour, minute], nil when absent, or :invalid when unparseable or
    # out of range. A missing time is reported, never widened to midnight: that
    # would invent a kickoff the source did not publish.
    def parse_time(value)
      text = value.to_s.strip
      return nil if text.empty?

      match = text.match(/\A(\d{1,2}):(\d{2})\z/)
      return :invalid unless match

      # Integer(..., 10): a leading zero is decimal padding, not octal.
      hour = Integer(match[1], 10)
      minute = Integer(match[2], 10)
      return :invalid if hour > 23 || minute > 59

      [hour, minute]
    end

    # Collapses internal whitespace and strips edges. Competition codes are
    # compared case-insensitively because "e0" and "E0" are one league.
    def normalize_text(value)
      value.to_s.strip.gsub(/\s+/, " ").upcase
    end

    def score?(value)
      value.to_s.strip.match?(/\A\d+\z/)
    end

    def blank?(value)
      value.nil? || value.to_s.strip.empty?
    end
  end
end
