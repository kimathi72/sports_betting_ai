class CreateCompetitions < ActiveRecord::Migration[7.1]
  def change
    create_table :competitions do |t|
      t.string :name, null: false
      # Short identifier such as "EPL". Nullable because not every source
      # supplies one, so it cannot be the primary identity.
      t.string :code
      t.string :country

      t.timestamps
    end

    # Names identify a competition in this platform. Enforced in the database
    # so concurrent imports cannot create duplicates.
    add_index :competitions, :name, unique: true

    # Partial unique index: codes must be unique when present, while any number
    # of competitions may have a NULL code.
    add_index :competitions, :code, unique: true, where: "code IS NOT NULL"
  end
end
