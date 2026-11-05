class AllowCorrectScorePredictionMarket < ActiveRecord::Migration[7.1]
  # Adds `correct_score` to the markets a stored prediction may declare.
  #
  # The database constraint is the last line of defence against a market that the
  # application does not actually support being persisted — which is why it is
  # widened deliberately, together with `Prediction::MARKETS`, and not dropped.
  #
  # Correct score is NOT a newly fitted model. It is the top-lines view of the joint
  # scoreline distribution that already backs 1X2, Over/Under and BTTS, so it can
  # never contradict them; the guarantee is checked by
  # `Prediction#validate_correct_score` (scoreline-shaped keys, probabilities within
  # [0,1], a truncated total that does not exceed 1).
  MARKETS = %w[1x2 double_chance over_under_2.5 btts correct_score].freeze

  def up
    remove_check_constraint :predictions, name: "predictions_market_supported"
    add_check_constraint :predictions,
                         "market IN (#{MARKETS.map { |m| "'#{m}'" }.join(', ')})",
                         name: "predictions_market_supported"
  end

  def down
    remove_check_constraint :predictions, name: "predictions_market_supported"
    previous = MARKETS - ["correct_score"]
    add_check_constraint :predictions,
                         "market IN (#{previous.map { |m| "'#{m}'" }.join(', ')})",
                         name: "predictions_market_supported"
  end
end
