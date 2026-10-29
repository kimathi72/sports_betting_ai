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

ActiveRecord::Schema[7.1].define(version: 2026_11_02_120000) do
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

  create_table "predictions", force: :cascade do |t|
    t.bigint "match_id", null: false
    t.string "model_version", null: false
    t.decimal "home_probability", precision: 6, scale: 5, null: false
    t.decimal "draw_probability", precision: 6, scale: 5, null: false
    t.decimal "away_probability", precision: 6, scale: 5, null: false
    t.datetime "generated_at", null: false
    t.jsonb "features", default: {}, null: false
    t.jsonb "model_metadata", default: {}, null: false
    t.datetime "superseded_at"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.string "market", default: "1x2", null: false
    t.jsonb "outcomes", default: {}, null: false
    t.index ["match_id", "generated_at"], name: "index_predictions_on_match_and_generated_at"
    t.index ["match_id", "market", "generated_at"], name: "index_predictions_on_match_market_generated_at"
    t.index ["match_id", "market"], name: "index_predictions_current_per_market", unique: true, where: "(superseded_at IS NULL)"
    t.index ["match_id", "model_version"], name: "index_predictions_on_match_and_model_version"
    t.index ["match_id"], name: "index_predictions_on_match_id"
    t.check_constraint "(home_probability + draw_probability + away_probability) = 1::numeric", name: "predictions_probabilities_sum_to_one"
    t.check_constraint "home_probability <= 1::numeric AND draw_probability <= 1::numeric AND away_probability <= 1::numeric", name: "predictions_probabilities_at_most_one"
    t.check_constraint "home_probability >= 0::numeric AND draw_probability >= 0::numeric AND away_probability >= 0::numeric", name: "predictions_probabilities_non_negative"
    t.check_constraint "jsonb_typeof(outcomes) = 'object'::text", name: "predictions_outcomes_is_object"
    t.check_constraint "market::text = ANY (ARRAY['1x2'::character varying, 'double_chance'::character varying, 'over_under_2.5'::character varying, 'btts'::character varying]::text[])", name: "predictions_market_supported"
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

  create_table "sync_runs", force: :cascade do |t|
    t.string "kind", null: false
    t.string "trigger", null: false
    t.string "status", default: "running", null: false
    t.datetime "started_at", null: false
    t.datetime "finished_at"
    t.integer "fetched", default: 0, null: false
    t.integer "created", default: 0, null: false
    t.integer "updated", default: 0, null: false
    t.integer "skipped", default: 0, null: false
    t.integer "rejected", default: 0, null: false
    t.text "last_error"
    t.jsonb "details", default: {}, null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["kind", "started_at"], name: "index_sync_runs_on_kind_and_started_at"
    t.index ["kind"], name: "index_sync_runs_one_running_per_kind", unique: true, where: "((status)::text = 'running'::text)"
    t.index ["status", "started_at"], name: "index_sync_runs_on_status_and_started_at"
    t.check_constraint "kind::text = ANY (ARRAY['fixtures'::character varying, 'results'::character varying]::text[])", name: "sync_runs_kind_check"
    t.check_constraint "status::text = ANY (ARRAY['running'::character varying, 'succeeded'::character varying, 'failed'::character varying]::text[])", name: "sync_runs_status_check"
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
  add_foreign_key "predictions", "matches"
  add_foreign_key "seasons", "competitions"
end
