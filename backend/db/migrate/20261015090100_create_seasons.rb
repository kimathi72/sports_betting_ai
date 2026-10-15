class CreateSeasons < ActiveRecord::Migration[7.1]
  def change
    create_table :seasons do |t|
      t.references :competition, null: false, foreign_key: true
      t.string :name, null: false
      t.date :start_date
      t.date :end_date

      t.timestamps
    end

    # A season label identifies a season within its competition only: providers
    # reuse labels like "2024/25" across leagues, so the scope is the pair.
    add_index :seasons, %i[competition_id name], unique: true

    # A season cannot end before it starts. Both dates are optional, so the
    # constraint only applies when both are present.
    add_check_constraint :seasons,
                         "start_date IS NULL OR end_date IS NULL OR start_date <= end_date",
                         name: "seasons_start_before_end"
  end
end
