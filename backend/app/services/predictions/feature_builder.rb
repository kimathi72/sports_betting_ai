module Predictions
  # Computes the ML service's 17 feature inputs from canonical match history.
  #
  # ⚠️ TEMPORARY BRIDGE — SEE docs/inference_contract.md
  #
  # Python owns feature engineering by agreement, and `ml/app/features.py` already
  # implements `compute_match_features`. That function is not reachable over HTTP
  # yet: the only inference endpoint accepts pre-computed flat features. Until Kilo
  # adds `POST /predict/from-history/{market}`, Rails must supply the features or
  # nothing can be predicted at all.
  #
  # This class exists ONLY for that gap and mirrors the Python formulas exactly.
  # When the history endpoint lands, delete this file and the call site; do not
  # extend it. It is deliberately the only place in Ruby that knows a feature
  # formula, so the duplication is bounded and obvious rather than spread around.
  #
  # TIME SAFETY is NOT duplicated here: the caller passes history that
  # `Predictions::MatchHistory` has already restricted to strictly-prior completed
  # matches. This class only aggregates what it is given.
  class FeatureBuilder
    # Must match ml/app/model_store.py::FEATURE_NAMES in order and name.
    FEATURE_NAMES = %w[
      home_last5_points home_last5_goals_for home_last5_goals_against
      home_last5_wins home_last5_draws home_last5_losses home_matches_played
      away_last5_points away_last5_goals_for away_last5_goals_against
      away_last5_wins away_last5_draws away_last5_losses away_matches_played
      h2h_home_wins h2h_draws h2h_away_wins
    ].freeze

    WINDOW = 5

    # `history` must already be time-safe (strictly before kickoff, completed).
    def self.call(match, history)
      new(match, history).call
    end

    def initialize(match, history)
      @match = match
      @history = history
    end

    def call
      home_id = match.home_team_id
      away_id = match.away_team_id

      home = form_for(home_id)
      away = form_for(away_id)
      h2h = head_to_head(home_id, away_id)

      {
        'home_last5_points' => home[:points],
        'home_last5_goals_for' => home[:goals_for],
        'home_last5_goals_against' => home[:goals_against],
        'home_last5_wins' => home[:wins],
        'home_last5_draws' => home[:draws],
        'home_last5_losses' => home[:losses],
        'home_matches_played' => home[:played],
        'away_last5_points' => away[:points],
        'away_last5_goals_for' => away[:goals_for],
        'away_last5_goals_against' => away[:goals_against],
        'away_last5_wins' => away[:wins],
        'away_last5_draws' => away[:draws],
        'away_last5_losses' => away[:losses],
        'away_matches_played' => away[:played],
        'h2h_home_wins' => h2h[:home_wins],
        'h2h_draws' => h2h[:draws],
        'h2h_away_wins' => h2h[:away_wins]
      }
    end

    private

    attr_reader :match, :history

    # Points, goals and W/D/L for one club over its most recent WINDOW completed
    # matches, counting only matches that club actually played.
    def form_for(team_id)
      played = history.select { |m| m['home_team_id'] == team_id || m['away_team_id'] == team_id }
                      .sort_by { |m| m['kickoff_at'].to_s }
                      .last(WINDOW)

      stats = { points: 0, goals_for: 0, goals_against: 0, wins: 0, draws: 0, losses: 0,
                played: played.length }

      played.each do |m|
        at_home = m['home_team_id'] == team_id
        scored = at_home ? m['home_score'].to_i : m['away_score'].to_i
        conceded = at_home ? m['away_score'].to_i : m['home_score'].to_i

        stats[:goals_for] += scored
        stats[:goals_against] += conceded

        if scored > conceded
          stats[:wins] += 1
          stats[:points] += 3
        elsif scored == conceded
          stats[:draws] += 1
          stats[:points] += 1
        else
          stats[:losses] += 1
        end
      end

      stats
    end

    # Head-to-head across the same history window, from the home club's point of
    # view. Only matches between these two clubs count.
    def head_to_head(home_id, away_id)
      meetings = history.select do |m|
        [m['home_team_id'], m['away_team_id']].sort == [home_id, away_id].sort
      end

      tally = { home_wins: 0, draws: 0, away_wins: 0 }

      meetings.each do |m|
        home_score = m['home_score'].to_i
        away_score = m['away_score'].to_i

        if home_score == away_score
          tally[:draws] += 1
        else
          winner = home_score > away_score ? m['home_team_id'] : m['away_team_id']
          winner == home_id ? tally[:home_wins] += 1 : tally[:away_wins] += 1
        end
      end

      tally
    end
  end
end
