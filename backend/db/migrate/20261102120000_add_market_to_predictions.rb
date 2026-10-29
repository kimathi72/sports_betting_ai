class AddMarketToPredictions < ActiveRecord::Migration[7.1]
  # Makes a prediction belong to a MARKET, not just a match.
  #
  # WHY THE CURRENT SHAPE IS INSUFFICIENT. The existing row stores exactly three
  # columns (home/draw/away), so a second market for the same fixture has nowhere
  # to go: writing over-the-2.5 goals into `home_probability` would corrupt the
  # 1X2 prediction and vice versa. Markets are independent statements about the
  # same match and must coexist.
  #
  # APPROACH: additive, not a rewrite. `market` defaults to '1x2', so every
  # existing row and every existing endpoint keeps its exact meaning. A new
  # `outcomes` jsonb holds the market-specific probabilities (e.g.
  # {"over"=>0.55,"under"=>0.45}), while the three legacy columns stay populated
  # for 1X2 so the current API and its specs are unaffected.
  #
  # CONSTRAINTS:
  #   - market must be one of the supported set (closed list, like match status)
  #   - only one CURRENT prediction per (match, market): a unique partial index,
  #     so concurrent writers cannot both leave an active prediction for a market
  #   - outcomes must be a JSON object, never an array or scalar
  def change
    add_column :predictions, :market, :string, null: false, default: "1x2"
    add_column :predictions, :outcomes, :jsonb, null: false, default: {}

    add_check_constraint :predictions,
                         "market IN ('1x2', 'double_chance', 'over_under_2.5', 'btts')",
                         name: "predictions_market_supported"

    add_check_constraint :predictions,
                         "jsonb_typeof(outcomes) = 'object'",
                         name: "predictions_outcomes_is_object"

    # One live prediction per market per match. Superseded rows are excluded, so
    # history is still kept.
    add_index :predictions,
              %i[match_id market],
              unique: true,
              where: "superseded_at IS NULL",
              name: "index_predictions_current_per_market"

    add_index :predictions, %i[match_id market generated_at],
              name: "index_predictions_on_match_market_generated_at"
  end
end
