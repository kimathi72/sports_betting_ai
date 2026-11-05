# The auditable link between an issued prediction and the verified result.
#
# Deliberately a separate row from `Prediction`: what we believed before kickoff and
# what happened afterwards are different evidence and must not be mixed in one
# mutable record.
class ProspectiveEvaluationRecord < ApplicationRecord
  belongs_to :prediction
  belongs_to :match

  validates :market, presence: true
  validates :actual_outcome, presence: true
  validates :home_score, :away_score, numericality: { only_integer: true, greater_than_or_equal_to: 0 }
  validates :evaluated_at, presence: true
  validates :prediction_id, uniqueness: { message: "has already been evaluated" }

  # The database has a unique index too; this validation exists to give a readable
  # error rather than a constraint violation.
  def self.evaluated?(prediction_id)
    exists?(prediction_id: prediction_id)
  end
end
