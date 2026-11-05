class AddProspectiveProvenanceToPredictions < ActiveRecord::Migration[7.1]
  # Columns needed to evaluate a prediction against its result, honestly.
  #
  # `issued_kickoff_at` records the kickoff the match had WHEN THE PREDICTION WAS
  # ISSUED. Without it, a fixture that is rescheduled after prediction is
  # indistinguishable from one that was correctly predicted for the new date, and
  # the rescheduled match would be scored as if the prediction had been made for the
  # new kickoff. The original `generated_at` cannot substitute: it says when the
  # prediction was made, not what it was made about.
  #
  # `model_freeze_digest` ties the prediction to a frozen generation (see
  # ml/evaluation/model_freeze_v2.1.json) so a result can be attributed to an
  # identifiable artifact set rather than to "whatever was deployed".
  #
  # Both are NULLABLE on purpose. Every existing prediction predates this change and
  # must keep a NULL rather than be assigned an invented value; a NULL means
  # "provenance unknown", and the eligibility check treats that as not eligible.
  def up
    add_column :predictions, :issued_kickoff_at, :datetime
    add_column :predictions, :model_freeze_digest, :string

    add_index :predictions, :model_freeze_digest
    # Supports the prospective sweep: completed matches with issued predictions.
    add_index :predictions, %i[match_id market generated_at]
  end

  def down
    remove_index :predictions, %i[match_id market generated_at]
    remove_index :predictions, :model_freeze_digest
    remove_column :predictions, :model_freeze_digest
    remove_column :predictions, :issued_kickoff_at
  end
end
