require "rails_helper"

# Contract for the read-only teams index. Teams are identified independently of
# competition or season, so the endpoint is a flat list.
#
# Public fields: id, name, country. `country` is nullable. `normalized_name` is
# deliberately NOT exposed: it is an internal uniqueness key used for provider
# deduplication, not part of the client-facing identity. Ordering is by name
# ascending with the id as a tie-breaker.
RSpec.describe "API v1 teams", type: :request do
  describe "GET /api/v1/teams" do
    it "responds with HTTP 200" do
      get "/api/v1/teams"

      expect(response).to have_http_status(:ok)
    end

    it "returns JSON" do
      get "/api/v1/teams"

      expect(response.media_type).to eq("application/json")
    end

    it "returns an empty array when no teams exist" do
      get "/api/v1/teams"

      expect(JSON.parse(response.body)).to eq([])
    end

    it "exposes the documented public fields" do
      team = Team.create!(name: "Arsenal", country: "England")

      get "/api/v1/teams"

      expect(JSON.parse(response.body)).to eq(
        [
          {
            "id" => team.id,
            "name" => "Arsenal",
            "country" => "England",
          },
        ]
      )
    end

    it "does not expose the internal normalized_name" do
      Team.create!(name: "Arsenal")

      get "/api/v1/teams"

      expect(JSON.parse(response.body).first).not_to have_key("normalized_name")
    end

    it "returns null for an absent country" do
      team = Team.create!(name: "Arsenal")

      get "/api/v1/teams"

      expect(JSON.parse(response.body).first["country"]).to be_nil
      expect(JSON.parse(response.body).first["id"]).to eq(team.id)
    end

    it "returns all persisted teams" do
      Team.create!(name: "Arsenal")
      Team.create!(name: "Chelsea")

      get "/api/v1/teams"

      expect(JSON.parse(response.body).size).to eq(2)
    end

    it "orders results by name ascending" do
      Team.create!(name: "Tottenham")
      Team.create!(name: "Arsenal")
      Team.create!(name: "Chelsea")

      get "/api/v1/teams"

      expect(JSON.parse(response.body).map { |t| t["name"] }).to eq(
        %w[Arsenal Chelsea Tottenham]
      )
    end

    it "uses the id as a deterministic tie-breaker" do
      first = Team.create!(name: "Arsenal")
      second = Team.create!(name: "Arsenal B")

      get "/api/v1/teams"

      expect(JSON.parse(response.body).map { |t| t["id"] }).to eq([first.id, second.id])
    end

    it "does not mutate the database" do
      Team.create!(name: "Arsenal")

      expect { get "/api/v1/teams" }.not_to change(Team, :count)
    end
  end
end
