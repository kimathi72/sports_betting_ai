class AddReviewStateToExternalIdentifiers < ActiveRecord::Migration[7.1]
  # Recorded mappings are either trusted or awaiting a human decision.
  #
  # Existing rows are all trusted: they were created by the importer or by
  # `espn:map_teams`, both of which only ever wrote a mapping after resolving a
  # unique candidate. New proposals from `espn:propose_team_mappings` start as
  # "pending" and are NOT used for reconciliation until approved, so a proposed
  # mapping can never move a fixture on its own.
  def up
    add_column :external_identifiers, :review_state, :string, null: false, default: "approved"
    add_index :external_identifiers, %i[provider review_state]
  end

  def down
    remove_index :external_identifiers, %i[provider review_state]
    remove_column :external_identifiers, :review_state
  end
end
