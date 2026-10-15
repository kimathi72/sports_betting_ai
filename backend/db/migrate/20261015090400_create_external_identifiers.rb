class CreateExternalIdentifiers < ActiveRecord::Migration[7.1]
  # Maps a provider's identifier for a football entity onto this platform's
  # canonical record.
  #
  # Design note: explicit nullable foreign keys rather than a Rails polymorphic
  # `*_type`/`*_id` pair. A polymorphic `*_id` column cannot carry a database
  # foreign key, so the referenced row would be unverifiable in PostgreSQL. Here
  # each target is a real FK and a check constraint requires exactly one of them.
  # The cost is four nullable columns; the benefit is real referential integrity.
  def change
    create_table :external_identifiers do |t|
      t.string :provider, null: false
      t.string :external_id, null: false

      t.references :competition, foreign_key: true
      t.references :season, foreign_key: true
      t.references :team, foreign_key: true
      t.references :match, foreign_key: true

      t.timestamps
    end

    # Exactly one target column must be populated. NULLIF-guarded so the count
    # treats a NULL as absent and any real id as present.
    add_check_constraint :external_identifiers,
                         "num_nonnulls(competition_id, season_id, team_id, match_id) = 1",
                         name: "external_identifiers_single_target"

    # A provider's identifier is unique within the provider and the entity type
    # it points at. Partial unique indexes per target keep duplicate mappings out
    # while still allowing the same external_id to be reused across providers or
    # across entity types. The `WHERE ... IS NOT NULL` predicate means each index
    # only considers rows whose target is that entity type.
    add_index :external_identifiers,
              %i[provider external_id],
              unique: true,
              where: "competition_id IS NOT NULL",
              name: "index_external_identifiers_on_provider_external_id_competition"

    add_index :external_identifiers,
              %i[provider external_id],
              unique: true,
              where: "season_id IS NOT NULL",
              name: "index_external_identifiers_on_provider_external_id_season"

    add_index :external_identifiers,
              %i[provider external_id],
              unique: true,
              where: "team_id IS NOT NULL",
              name: "index_external_identifiers_on_provider_external_id_team"

    add_index :external_identifiers,
              %i[provider external_id],
              unique: true,
              where: "match_id IS NOT NULL",
              name: "index_external_identifiers_on_provider_external_id_match"
  end
end
