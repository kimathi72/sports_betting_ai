class AddNormalizedNameToTeams < ActiveRecord::Migration[7.1]
  # Team `name` was previously the unique identity, which assumed every source
  # spells a team identically. Real sources vary in case, spacing and accents,
  # so identity is moved to a deterministic `normalized_name`.
  #
  # Existing rows: none are assumed. If rows existed, they would be backfilled
  # from `name` before the NOT NULL constraint is applied.
  def up
    add_column :teams, :normalized_name, :string
    add_column :teams, :country, :string

    execute <<~SQL
      UPDATE teams
      SET normalized_name = regexp_replace(
        lower(translate(name, 'ÀÁÂÃÄÅàáâãäåÈÉÊËèéêëÌÍÎÏìíîïÒÓÔÕÖòóôõöÙÚÛÜùúûüÇçÑñ',
                          'AAAAAAaaaaaaEEEEeeeeIIIIiiiiOOOOOoooooUUUUuuuuCcNn')),
        '\s+', ' ', 'g'
      )
      WHERE normalized_name IS NULL
    SQL

    change_column_null :teams, :normalized_name, false

    # Identity moves from the raw display name to the normalized projection.
    remove_index :teams, :name
    add_index :teams, :normalized_name, unique: true
  end

  def down
    remove_index :teams, :normalized_name
    add_index :teams, :name, unique: true
    remove_column :teams, :country
    remove_column :teams, :normalized_name
  end
end
