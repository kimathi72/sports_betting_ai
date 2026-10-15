class CreateTeams < ActiveRecord::Migration[7.1]
  def change
    create_table :teams do |t|
      t.string :name, null: false

      t.timestamps
    end

    # Names are the natural key for teams in this platform; enforce uniqueness
    # in the database, not only in the model, so concurrent imports cannot
    # create duplicates.
    add_index :teams, :name, unique: true
  end
end
