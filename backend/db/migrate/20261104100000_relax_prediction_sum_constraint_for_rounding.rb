class RelaxPredictionSumConstraintForRounding < ActiveRecord::Migration[7.1]
  # WHY
  # ---
  # `home_probability`, `draw_probability` and `away_probability` are
  # `numeric(6,5)`. The ML service rounds each probability to five decimals
  # INDEPENDENTLY, and the sum of three independently-rounded numbers is not
  # always exactly 1 — it can be 1.00001 or 0.99999.
  #
  # On 2026-11-04 a genuine distribution (0.409353…, 0.271295…, 0.319353…) was
  # stored as (0.40935, 0.27130, 0.31936), summing to 1.00001, and
  # `predictions_probabilities_sum_to_one` rejected the write. POST
  # /api/v1/predictions returned HTTP 500 for 5 of 11 competitions.
  #
  # The original constraint demanded that the schema enforce something the
  # storage format cannot represent. The alternative "fix" — nudging one
  # probability so the stored digits add up — would silently edit the model's
  # output and make the stored prediction differ from the one that was issued.
  #
  # WHAT CHANGES
  # ------------
  # The exact equality becomes a tolerance of 0.00001. That is less than one
  # unit in the last stored digit times three (the most rounding can shift a sum
  # of three five-decimal values is 0.000015), and it still rejects a
  # distribution that is wrong in any way an operator would notice: a sum of
  # 1.0001 or 0.9998 fails.
  #
  # The other three constraints are untouched and remain exact:
  #   predictions_probabilities_non_negative
  #   predictions_probabilities_at_most_one
  #   double chance agreement with 1X2 (a model-level validation)
  #
  # NO DATA IS TOUCHED. Existing rows all satisfy the looser constraint by
  # construction, so nothing has to be rewritten, and a row that failed the old
  # constraint was never stored in the first place.
  TOLERANCE = "0.00001".freeze

  def up
    remove_check_constraint :predictions, name: "predictions_probabilities_sum_to_one"

    add_check_constraint :predictions,
                         "home_probability + draw_probability + away_probability BETWEEN " \
                         "1 - #{TOLERANCE} AND 1 + #{TOLERANCE}",
                         name: "predictions_probabilities_sum_to_one"
  end

  def down
    remove_check_constraint :predictions, name: "predictions_probabilities_sum_to_one"

    # Tightening back can only succeed if no stored row needed the tolerance. If
    # one does, this raises instead of silently leaving rows the old constraint
    # would have rejected — a rollback must not create data the forward migration
    # declared invalid.
    add_check_constraint :predictions,
                         "home_probability + draw_probability + away_probability = 1",
                         name: "predictions_probabilities_sum_to_one"
  end
end
