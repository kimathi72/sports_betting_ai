class CreateProspectiveEvaluationRecords < ActiveRecord::Migration[7.1]
  # The auditable link between an issued prediction and its verified outcome.
  #
  # A separate table rather than columns on `predictions`, for one reason: the
  # prediction is evidence of what we believed before kickoff, and the evaluation is
  # evidence of what happened. Writing the outcome into the prediction row would
  # make the two indistinguishable and would put mutable data next to immutable data.
  #
  # The unique index on `prediction_id` is the database-level guarantee that a
  # prediction is never scored twice — a Ruby check alone would race.
  def up
    create_table :prospective_evaluation_records do |t|
      t.references :prediction, null: false, foreign_key: true, index: { unique: true }
      t.references :match, null: false, foreign_key: true

      t.string  :market, null: false
      t.string  :actual_outcome, null: false
      t.string  :predicted_outcome
      t.integer :home_score, null: false
      t.integer :away_score, null: false

      t.float   :log_loss
      t.boolean :was_correct

      # Provenance of the evidence itself: which protocol governed the run and when.
      t.string  :protocol_digest
      t.datetime :evaluated_at, null: false

      t.timestamps
    end

    add_index :prospective_evaluation_records, %i[market evaluated_at]
    add_check_constraint :prospective_evaluation_records,
                         "home_score >= 0 AND away_score >= 0",
                         name: "prospective_evaluations_non_negative_scores"
  end

  def down
    drop_table :prospective_evaluation_records
  end
end
