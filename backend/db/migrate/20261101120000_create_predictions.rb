class CreatePredictions < ActiveRecord::Migration[7.1]
  # Stores a 1X2 prediction for one fixture, produced by one model version.
  #
  # Design notes:
  #
  # - Probabilities are stored as PostgreSQL `numeric`, not floats. A float would
  #   make "these three numbers sum to exactly 1" an accident of rounding; numeric
  #   with an explicit scale keeps the check constraint meaningful and lets the
  #   stored value be compared to what the model returned.
  #
  # - `superseded_at` instead of deleting. Regenerating a prediction must not
  #   erase what was previously believed, because evaluating a model later needs
  #   to know what it said at the time. `current` = superseded_at IS NULL.
  #
  # - `features` and `model_metadata` are jsonb so a prediction can be reproduced
  #   and audited without a schema change per feature.
  #
  # - `model_version` is a plain string for now. There is no model registry table
  #   yet, and inventing one before the ML service publishes stable model records
  #   would create a second concept that has to be reconciled later.
  def change
    create_table :predictions do |t|
      t.references :match, null: false, foreign_key: true

      # Identifies the model that produced this prediction.
      t.string :model_version, null: false

      # 1X2 outcome probabilities. numeric(6,5) allows 0.00000..1.00000 with
      # enough precision to keep the sum check exact for typical outputs.
      t.decimal :home_probability, precision: 6, scale: 5, null: false
      t.decimal :draw_probability, precision: 6, scale: 5, null: false
      t.decimal :away_probability, precision: 6, scale: 5, null: false

      t.datetime :generated_at, null: false

      # The feature vector the model saw, and any model metadata worth keeping
      # (training timestamp, feature count, metrics). Both default to {} so a
      # consumer never has to handle null.
      t.jsonb :features, null: false, default: {}
      t.jsonb :model_metadata, null: false, default: {}

      # Set when a newer prediction for the same match replaces this one.
      t.datetime :superseded_at

      t.timestamps
    end

    add_check_constraint :predictions,
                         "home_probability >= 0 AND draw_probability >= 0 AND away_probability >= 0",
                         name: "predictions_probabilities_non_negative"

    add_check_constraint :predictions,
                         "home_probability <= 1 AND draw_probability <= 1 AND away_probability <= 1",
                         name: "predictions_probabilities_at_most_one"

    # A real distribution, enforced even for writes that bypass ActiveRecord.
    add_check_constraint :predictions,
                         "home_probability + draw_probability + away_probability = 1",
                         name: "predictions_probabilities_sum_to_one"

    # Fast lookup of the live prediction for a match, and of prediction history.
    add_index :predictions, %i[match_id generated_at], name: "index_predictions_on_match_and_generated_at"
    add_index :predictions, %i[match_id model_version],
              name: "index_predictions_on_match_and_model_version"
  end
end
