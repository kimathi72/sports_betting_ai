# This file is auto-generated from the current state of the database. Instead
# of editing this file, please use the migrations feature of Active Record to
# incrementally modify your database, and then regenerate this schema definition.
#
# This file is the source Rails uses to define your schema when running `bin/rails
# db:schema:load`. When creating a new database, `bin/rails db:schema:load` tends to
# be faster and is potentially less error prone than running all of your
# migrations from scratch. Old migrations may fail to apply correctly if those
# migrations use external dependencies or application code.
#
# It's strongly recommended that you check this file into your version control system.

ActiveRecord::Schema[7.1].define(version: 2026_10_15_090400) do
  # These are extensions that must be enabled in order to support this database
  enable_extension "plpgsql"

  create_table "competitions", force: :cascade do |t|
    t.string "name", null: false
    t.string "code"
    t.string "country"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["code"], name: "index_competitions_on_code", unique: true, where: "(code IS NOT NULL)"
    t.index ["name"], name: "index_competitions_on_name", unique: true
  end

  create_table "external_identifiers", force: :cascade do |t|
    t.string "provider", null: false
    t.string "external_id", null: false
    t.bigint "competition_id"
    t.bigint "season_id"
    t.bigint "team_id"
    t.bigint "match_id"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["competition_id"], name: "index_external_identifiers_on_competition_id"
    t.index ["match_id"], name: "index_external_identifiers_on_match_id"
    t.index ["provider", "external_id"], name: "index_external_identifiers_on_provider_external_id_competition", unique: true, where: "(competition_id IS NOT NULL)"
    t.index ["provider", "external_id"], name: "index_external_identifiers_on_provider_external_id_match", unique: true, where: "(match_id IS NOT NULL)"
    t.index ["provider", "external_id"], name: "index_external_identifiers_on_provider_external_id_season", unique: true, where: "(season_id IS NOT NULL)"
    t.index ["provider", "external_id"], name: "index_external_identifiers_on_provider_external_id_team", unique: true, where: "(team_id IS NOT NULL)"
    t.index ["season_id"], name: "index_external_identifiers_on_season_id"
    t.index ["team_id"], name: "index_external_identifiers_on_team_id"
    t.check_constraint "num_nonnulls(competition_id, season_id, team_id, match_id) = 1", name: "external_identifiers_single_target"
  end

  create_table "matches", force: :cascade do |t|
    t.bigint "competition_id", null: false
    t.bigint "season_id", null: false
    t.bigint "home_team_id", null: false
    t.bigint "away_team_id", null: false
    t.datetime "kickoff_at", null: false
    t.string "status", null: false
    t.integer "home_score"
    t.integer "away_score"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["away_team_id"], name: "index_matches_on_away_team_id"
    t.index ["competition_id"], name: "index_matches_on_competition_id"
    t.index ["home_team_id"], name: "index_matches_on_home_team_id"
    t.index ["kickoff_at"], name: "index_matches_on_kickoff_at"
    t.index ["season_id", "kickoff_at"], name: "index_matches_on_season_id_and_kickoff_at"
    t.index ["season_id"], name: "index_matches_on_season_id"
    t.index ["status"], name: "index_matches_on_status"
    t.check_constraint "(home_score IS NULL OR home_score >= 0) AND (away_score IS NULL OR away_score >= 0)", name: "matches_scores_non_negative"
    t.check_constraint "(home_score IS NULL) = (away_score IS NULL)", name: "matches_scores_paired"
    t.check_constraint "home_team_id <> away_team_id", name: "matches_teams_differ"
    t.check_constraint "status::text <> 'completed'::text OR home_score IS NOT NULL AND away_score IS NOT NULL", name: "matches_completed_has_scores"
    t.check_constraint "status::text = ANY (ARRAY['scheduled'::character varying, 'postponed'::character varying, 'cancelled'::character varying, 'in_progress'::character varying, 'completed'::character varying]::text[])", name: "matches_status_supported"
  end

  create_table "seasons", force: :cascade do |t|
    t.bigint "competition_id", null: false
    t.string "name", null: false
    t.date "start_date"
    t.date "end_date"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["competition_id", "name"], name: "index_seasons_on_competition_id_and_name", unique: true
    t.index ["competition_id"], name: "index_seasons_on_competition_id"
    t.check_constraint "start_date IS NULL OR end_date IS NULL OR start_date <= end_date", name: "seasons_start_before_end"
  end

  create_table "teams", force: :cascade do |t|
    t.string "name", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.string "normalized_name", null: false
    t.string "country"
    t.index ["normalized_name"], name: "index_teams_on_normalized_name", unique: true
  end

  add_foreign_key "external_identifiers", "competitions"
  add_foreign_key "external_identifiers", "matches"
  add_foreign_key "external_identifiers", "seasons"
  add_foreign_key "external_identifiers", "teams"
  add_foreign_key "matches", "competitions"
  add_foreign_key "matches", "seasons"
  add_foreign_key "matches", "teams", column: "away_team_id"
  add_foreign_key "matches", "teams", column: "home_team_id"
  add_foreign_key "seasons", "competitions"
end
