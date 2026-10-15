class CreateMatches < ActiveRecord::Migration[7.1]
  # Supported match statuses. Kept in sync with Match::STATUSES.
  STATUSES = %w[scheduled postponed cancelled in_progress completed].freeze

  def change
    create_table :matches do |t|
      t.references :competition, null: false, foreign_key: true
      t.references :season, null: false, foreign_key: true
      t.references :home_team, null: false, foreign_key: { to_table: :teams }
      t.references :away_team, null: false, foreign_key: { to_table: :teams }

      t.datetime :kickoff_at, null: false
      t.string :status, null: false
      t.integer :home_score
      t.integer :away_score

      t.timestamps
    end

    # --- Domain invariants, enforced in the database -------------------------

    # A team cannot play itself.
    add_check_constraint :matches,
                         "home_team_id <> away_team_id",
                         name: "matches_teams_differ"

    # Status must belong to the supported set.
    add_check_constraint :matches,
                         "status IN (#{STATUSES.map { |s| "'#{s}'" }.join(", ")})",
                         name: "matches_status_supported"

    # Scores are never negative.
    add_check_constraint :matches,
                         "(home_score IS NULL OR home_score >= 0) AND " \
                         "(away_score IS NULL OR away_score >= 0)",
                         name: "matches_scores_non_negative"

    # Scores are either both present or both absent.
    add_check_constraint :matches,
                         "(home_score IS NULL) = (away_score IS NULL)",
                         name: "matches_scores_paired"

    # A completed match must carry both scores.
    add_check_constraint :matches,
                         "status <> 'completed' OR (home_score IS NOT NULL AND away_score IS NOT NULL)",
                         name: "matches_completed_has_scores"

    # --- Indexes for expected access patterns -------------------------------

    # Reference-style indexes on competition/season/teams are created by
    # t.references above. These add the remaining lookup paths.
    add_index :matches, %i[season_id kickoff_at]
    add_index :matches, :kickoff_at
    add_index :matches, :status
  end
end
