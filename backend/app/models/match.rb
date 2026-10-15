# A football fixture and, once played, its final result.
#
# Integrity is enforced at two levels. The model validations give useful error
# messages to callers; the PostgreSQL check constraints in the matches
# migration guarantee the same invariants even when a write bypasses
# ActiveRecord (bulk inserts, imports, migrations, console SQL).
class Match < ApplicationRecord
  # Statuses are a closed set. A match may not carry an arbitrary string.
  STATUSES = %w[scheduled postponed cancelled in_progress completed].freeze

  belongs_to :competition
  belongs_to :season
  belongs_to :home_team, class_name: "Team", inverse_of: :home_matches
  belongs_to :away_team, class_name: "Team", inverse_of: :away_matches

  validates :kickoff_at, presence: true
  validates :status, presence: true, inclusion: { in: STATUSES }
  validates :home_score, :away_score,
            numericality: { only_integer: true, greater_than_or_equal_to: 0 },
            allow_nil: true

  validate :teams_must_differ
  validate :season_must_belong_to_competition
  validate :scores_must_be_paired
  validate :completed_matches_must_have_scores

  scope :completed, -> { where(status: "completed") }
  scope :upcoming, -> { where(status: "scheduled").where("kickoff_at >= ?", Time.current) }

  private

  def teams_must_differ
    return if home_team_id.blank? || away_team_id.blank?
    return if home_team_id != away_team_id

    errors.add(:away_team, "must be different from the home team")
  end

  # Cross-table invariant: the season must belong to the competition the match
  # references. There is no composite foreign key for this, so the rule is
  # enforced here only — see docs/roadmap.md for the documented limitation.
  def season_must_belong_to_competition
    return if season.blank? || competition_id.blank?
    return if season.competition_id == competition_id

    errors.add(:season, "must belong to the match's competition")
  end

  def scores_must_be_paired
    return if home_score.nil? == away_score.nil?

    errors.add(:base, "home and away scores must both be present or both be absent")
  end

  def completed_matches_must_have_scores
    return unless status == "completed"
    return if home_score.present? && away_score.present?

    errors.add(:base, "a completed match must have both scores")
  end
end
