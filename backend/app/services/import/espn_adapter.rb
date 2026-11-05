require 'time'

module Import
  # Normalises ESPN soccer scoreboard events into internal rows.
  #
  # WHY ESPN
  # --------
  # It serves the current season without an API key. That is the specific gap the
  # API-Football free tier leaves, and it is why this adapter exists.
  #
  # The output is deliberately the SAME `FixtureRow` shape the API-Football
  # adapter produces, so the existing reconciler, synchronizer and ledger all
  # work unchanged. A second row shape would mean a second write path and a
  # second set of duplicate-prevention rules.
  #
  # STATUS PRECEDENCE
  # -----------------
  # ESPN exposes both a status NAME and a `state` (`pre`/`in`/`post`) plus a
  # `completed` flag. The name is checked FIRST for the terminal-but-not-played
  # cases (postponed, cancelled, abandoned), because ESPN has been observed
  # setting `completed: true` on those. Only then does `state` decide. Getting
  # this backwards would import a postponed match as a played one.
  class EspnAdapter
    PROVIDER = 'espn'.freeze

    # Checked before `state`, because a postponed/cancelled match can still be
    # reported as completed.
    NON_PLAYED_STATUSES = {
      'STATUS_POSTPONED' => 'postponed',
      'STATUS_CANCELED' => 'cancelled',
      'STATUS_CANCELLED' => 'cancelled',
      'STATUS_ABANDONED' => 'cancelled',
      'STATUS_SUSPENDED' => 'in_progress',
      'STATUS_DELAYED' => 'scheduled'
    }.freeze

    # Fallback when only the state is usable.
    STATE_STATUS = { 'pre' => 'scheduled', 'in' => 'in_progress', 'post' => 'completed' }.freeze

    def normalize_fixture(payload)
      return nil unless payload.is_a?(Hash)

      event_id = payload['id']
      competition = Array(payload['competitions']).first
      return nil if event_id.nil? || !competition.is_a?(Hash)

      competitors = Array(competition['competitors'])
      return nil unless competitors.size == 2

      home = competitors.find { |c| c['homeAway'] == 'home' }
      away = competitors.find { |c| c['homeAway'] == 'away' }
      return nil if home.nil? || away.nil?

      home_id = home.dig('team', 'id')
      away_id = away.dig('team', 'id')
      return nil if home_id.nil? || away_id.nil? || home_id.to_s == away_id.to_s

      kickoff = parse_time(payload['date'])
      return nil if kickoff.nil?

      status = resolve_status(competition)
      season_year = payload.dig('season', 'year')&.to_s

      # Scores ONLY for a completed match — the same guard as API-Football.
      home_score, away_score =
        if status == 'completed'
          [integer_or_nil(home['score']), integer_or_nil(away['score'])]
        else
          [nil, nil]
        end

      ApiFootballAdapter::FixtureRow.new(
        provider: PROVIDER,
        provider_key: event_id.to_s,
        status: status,
        kickoff_at: kickoff,
        home_score: home_score,
        away_score: away_score,
        home_provider_team_id: home_id.to_s,
        away_provider_team_id: away_id.to_s,
        home_team_name: home.dig('team', 'displayName'),
        away_team_name: away.dig('team', 'displayName'),
        provider_league_id: nil,
        provider_season_year: season_year,
        provider_league_name: nil
      )
    end

    private

    # Name first, state second. See the class comment for why the order matters.
    def resolve_status(competition)
      type = competition.dig('status', 'type') || {}
      named = NON_PLAYED_STATUSES[type['name']]
      return named if named

      STATE_STATUS[type['state']]
    end

    def parse_time(value)
      return nil if value.blank?

      Time.parse(value.to_s).utc
    rescue ArgumentError, TypeError
      nil
    end

    def integer_or_nil(value)
      return nil if value.nil? || value.to_s.strip.empty?

      Integer(value)
    rescue ArgumentError, TypeError
      nil
    end
  end
end
