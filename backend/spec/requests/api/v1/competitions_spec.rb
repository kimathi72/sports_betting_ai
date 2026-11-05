require "rails_helper"

# Contract for the read-only competitions index. The endpoint exposes the
# canonical competition records to the mobile client and internal tooling.
#
# Public fields: id, name, code, country, region, seasons, current_season,
# match_count, completed_count. `code` and `country` are nullable in the schema, so
# they appear as null in JSON when absent. Ordering is by name ascending with the
# id as a tie-breaker, so the payload is deterministic even when two competitions
# share a name (which the model forbids, but the ordering contract should not depend
# on that).
#
# `region`, `seasons`, `current_season`, `match_count` and `completed_count` were
# added for the mobile app: the competition card shows the available season and
# match count, the region filter groups by `region`, and the Home activity summary
# counts real fixtures. They are additive — existing fields keep their meaning and
# position.
RSpec.describe "API v1 competitions", type: :request do
  describe "GET /api/v1/competitions" do
    it "responds with HTTP 200" do
      get "/api/v1/competitions"

      expect(response).to have_http_status(:ok)
    end

    it "returns JSON" do
      get "/api/v1/competitions"

      expect(response.media_type).to eq("application/json")
    end

    it "returns an empty array when no competitions exist" do
      get "/api/v1/competitions"

      expect(JSON.parse(response.body)).to eq([])
    end

    it "exposes the documented public fields" do
      competition = Competition.create!(
        name: "Premier League", code: "EPL", country: "England"
      )

      get "/api/v1/competitions"

      payload = JSON.parse(response.body).first

      expect(payload).to include(
        "id" => competition.id,
        "name" => "Premier League",
        "code" => "EPL",
        "country" => "England",
        "match_count" => 0,
        "completed_count" => 0,
        "seasons" => [],
        "current_season" => nil
      )
    end

    it "reports region from the competition catalogue" do
      Competition.create!(name: "La Liga", code: "SP1", country: "Spain")

      get "/api/v1/competitions"

      expect(JSON.parse(response.body).first["region"]).to eq("europe")
    end

    it "reports a competition outside the catalogue as other, not a guess" do
      Competition.create!(name: "Unknown Cup", code: "ZZ9")

      get "/api/v1/competitions"

      expect(JSON.parse(response.body).first["region"]).to eq("other")
    end

    it "reports the seasons and match counts that actually exist" do
      competition = Competition.create!(name: "Serie A", code: "I1", country: "Italy")
      season = Season.create!(competition: competition, name: "2024/25")
      home = Team.create!(name: "Inter")
      away = Team.create!(name: "Juventus")
      Match.create!(competition: competition, season: season, home_team: home, away_team: away,
                    kickoff_at: Time.utc(2024, 9, 1), status: "completed", home_score: 2, away_score: 1)
      Match.create!(competition: competition, season: season, home_team: away, away_team: home,
                    kickoff_at: Time.utc(2024, 12, 1), status: "scheduled")

      get "/api/v1/competitions"

      payload = JSON.parse(response.body).first
      expect(payload["seasons"]).to eq(["2024/25"])
      expect(payload["current_season"]).to eq("2024/25")
      expect(payload["match_count"]).to eq(2)
      expect(payload["completed_count"]).to eq(1)
    end

    it "returns null for absent optional fields" do
      competition = Competition.create!(name: "La Liga")

      get "/api/v1/competitions"

      payload = JSON.parse(response.body).first
      expect(payload["id"]).to eq(competition.id)
      expect(payload["name"]).to eq("La Liga")
      expect(payload["code"]).to be_nil
      expect(payload["country"]).to be_nil
    end

    it "returns all persisted competitions" do
      Competition.create!(name: "Premier League")
      Competition.create!(name: "La Liga")

      get "/api/v1/competitions"

      expect(JSON.parse(response.body).size).to eq(2)
    end

    it "orders results by name ascending" do
      Competition.create!(name: "Serie A")
      Competition.create!(name: "La Liga")
      Competition.create!(name: "Bundesliga")

      get "/api/v1/competitions"

      expect(JSON.parse(response.body).map { |c| c["name"] }).to eq(
        ["Bundesliga", "La Liga", "Serie A"]
      )
    end

    it "uses the id as a deterministic tie-breaker" do
      first = Competition.create!(name: "Premier League")
      second = Competition.create!(name: "Premier League B")

      get "/api/v1/competitions"

      ids = JSON.parse(response.body).map { |c| c["id"] }
      expect(ids).to eq([first.id, second.id])
    end

    it "does not mutate the database" do
      Competition.create!(name: "Premier League")

      expect { get "/api/v1/competitions" }.not_to change(Competition, :count)
    end
  end
end
