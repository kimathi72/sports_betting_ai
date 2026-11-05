require "time"

module Import
  # Normalises API-Football fixture payloads into internal rows.
  #
  # Pure: no database access, no HTTP. It is the only class that knows the
  # provider's field names and status vocabulary, mirroring
  # `FootballDataCoUkAdapter`. Everything above it works with `FixtureRow`.
  #
  # THE TWO RULES THAT MATTER MOST
  # ------------------------------
  # 1. A live score is NEVER a final score. The provider reports `goals` for a
  #    match in progress; importing that as a result would put an unfinished
  #    match into the training set.
  # 2. An unknown status yields `nil`, not a guess. A silently invented status
  #    would be harder to detect than a rejected row.
  class ApiFootballAdapter
    PROVIDER = "api_football".freeze

    # Provider status codes, documented at api-sports.io. `AWD` is an awarded
    # result: the score line is administrative, so it is treated as cancelled
    # rather than as a played fixture.
    COMPLETED_STATUSES = %w[FT AET PEN].freeze
    LIVE_STATUSES = %w[1H HT 2H ET BT P SUSP INT].freeze
    POSTPONED_STATUSES = %w[PST].freeze
    CANCELLED_STATUSES = %w[CANC ABD AWD WO].freeze
    SCHEDULED_STATUSES = %w[NS TBD].freeze

    STATUS_MAP = {}.tap do |map|
      COMPLETED_STATUSES.each { |code| map[code] = "completed" }
      LIVE_STATUSES.each { |code| map[code] = "in_progress" }
      POSTPONED_STATUSES.each { |code| map[code] = "postponed" }
      CANCELLED_STATUSES.each { |code| map[code] = "cancelled" }
      SCHEDULED_STATUSES.each { |code| map[code] = "scheduled" }
    end.freeze

    FixtureRow = Struct.new(
      :provider, :provider_key, :status, :kickoff_at,
      :home_score, :away_score,
      :home_provider_team_id, :away_provider_team_id,
      :home_team_name, :away_team_name,
      :provider_league_id, :provider_season_year,
      :provider_league_name,
      keyword_init: true,
    )

    # Returns a FixtureRow, or nil when the payload cannot be trusted.
    #
    # nil is deliberate: a rejected row is counted and reported, whereas a
    # partially-populated row would be persisted with missing identity.
    def normalize_fixture(payload)
      return nil unless payload.is_a?(Hash)

      fixture = payload["fixture"]
      teams = payload["teams"]
      league = payload["league"]
      return nil unless fixture.is_a?(Hash) && teams.is_a?(Hash)

      fixture_id = fixture["id"]
      home = teams.dig("home", "id")
      away = teams.dig("away", "id")
      return nil if fixture_id.nil? || home.nil? || away.nil?
      # Identical ids mean a malformed payload; two different teams share no id.
      return nil if home.to_s == away.to_s

      kickoff = parse_time(fixture["date"])
      return nil if kickoff.nil?

      status = STATUS_MAP[fixture.dig("status", "short").to_s]
      goals = payload["goals"].is_a?(Hash) ? payload["goals"] : {}

      # Scores are attached ONLY to a completed match. This single guard is what
      # keeps live and upcoming fixtures out of the labelled training data.
      home_score, away_score = if status == "completed"
          [integer_or_nil(goals["home"]), integer_or_nil(goals["away"])]
        else
          [nil, nil]
        end

      FixtureRow.new(
        provider: PROVIDER,
        provider_key: fixture_id.to_s,
        status: status,
        kickoff_at: kickoff,
        home_score: home_score,
        away_score: away_score,
        home_provider_team_id: home.to_s,
        away_provider_team_id: away.to_s,
        home_team_name: teams.dig("home", "name"),
        away_team_name: teams.dig("away", "name"),
        provider_league_id: league.is_a?(Hash) ? league["id"]&.to_s : nil,
        provider_season_year: league.is_a?(Hash) ? league["season"]&.to_s : nil,
        provider_league_name: league.is_a?(Hash) ? league["name"] : nil,
      )
    end

    private

    # Always UTC. The provider returns an offset (`+00:00`, but not always);
    # `Time.parse` honours it, so a CEST kickoff does not silently shift an hour.
    def parse_time(value)
      return nil if value.blank?

      Time.parse(value.to_s).utc
    rescue ArgumentError, TypeError
      nil
    end

    def integer_or_nil(value)
      return nil if value.nil?

      Integer(value)
    rescue ArgumentError, TypeError
      nil
    end
  end
end
