module Sync
  # Which provider season a date belongs to.
  #
  # The provider publishes one CSV per SEASON, and every fixture of that season
  # (played or not) lives in it. So "fetch upcoming fixtures" and "fetch newly
  # completed results" are both "refresh the current season file and import it" —
  # the file contains the scheduled rows too, with empty score columns.
  #
  # The season boundary is deliberately explicit rather than derived from
  # Time.current.month in a dozen places. A European league season labelled
  # "2026/27" runs from roughly July 2026 to May 2027, so a match played in
  # January 2027 belongs to 2026/27, not 2027/28. Getting this wrong silently
  # imports the previous season's file and reports success with 0 new rows.
  module SeasonWindow
    # Rows on or after this month/day start a new season label.
    SEASON_START_MONTH = 7

    module_function

    # "2026/27" for any date in the 2026/27 season.
    def current_label(at: Time.current)
      year = at.year
      year -= 1 if at.month < SEASON_START_MONTH
      "#{year}/#{format('%02d', (year + 1) % 100)}"
    end

    def previous_label(at: Time.current)
      year = at.year
      year -= 1 if at.month < SEASON_START_MONTH
      previous = year - 1
      "#{previous}/#{format('%02d', (previous + 1) % 100)}"
    end

    # Provider file codes are two-digit: "2627" -> "2026/27".
    def label_from_code(code)
      text = code.to_s.strip
      unless text.match?(/\A\d{4}\z/)
        raise ArgumentError, "season file code must be four digits, got #{code.inspect}"
      end

      start = 2000 + text[0, 2].to_i
      finish = 2000 + text[2, 2].to_i
      "#{start}/#{format('%02d', finish % 100)}"
    end

    def code_for(label)
      match = label.to_s.strip.match(%r{\A(\d{4})/(\d{2}|\d{4})\z})
      raise ArgumentError, "unrecognised season label #{label.inspect}" unless match

      start = match[1]
      finish = match[2].length == 2 ? match[2] : match[2][-2..]
      "#{start[-2..]}#{finish}"
    end
  end
end
