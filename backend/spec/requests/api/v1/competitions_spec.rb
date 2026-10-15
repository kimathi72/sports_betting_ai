require "rails_helper"

# Contract for the read-only competitions index. The endpoint exposes the
# canonical competition records to the mobile client and internal tooling.
#
# Public fields: id, name, code, country. `code` and `country` are nullable in
# the schema, so they appear as null in JSON when absent. Ordering is by name
# ascending with the id as a tie-breaker, so the payload is deterministic even
# when two competitions share a name (which the model forbids, but the ordering
# contract should not depend on that).
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

      expect(JSON.parse(response.body)).to eq(
        [
          {
            "id" => competition.id,
            "name" => "Premier League",
            "code" => "EPL",
            "country" => "England",
          },
        ]
      )
    end

    it "returns null for absent optional fields" do
      competition = Competition.create!(name: "La Liga")

      get "/api/v1/competitions"

      expect(JSON.parse(response.body).first).to eq(
        "id" => competition.id,
        "name" => "La Liga",
        "code" => nil,
        "country" => nil
      )
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
