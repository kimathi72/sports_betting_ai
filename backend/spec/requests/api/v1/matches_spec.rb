require "rails_helper"

# Contract for the read-only matches index. A match is a fixture and, once
# played, its final result, so this is the richest read payload in Phase 3.
#
# Public fields: id, competition_id, season_id, home_team_id, away_team_id,
# kickoff_at, status, home_score, away_score. All of these exist in the actual
# schema; `home_score`/`away_score` are nullable and appear as null for a fixture
# that has not completed. `kickoff_at` is NOT NULL in the schema, so a null
# kickoff cannot be stored and is not representable in the payload.
#
# Ordering policy: `kickoff_at` ascending, with the id as a tie-breaker so that
# fixtures kicking off at the same instant have a stable, reproducible order.
RSpec.describe "API v1 matches", type: :request do
  let(:competition) { Competition.create!(name: "Premier League") }
  let(:season) { Season.create!(competition: competition, name: "2024/25") }
  let(:home_team) { Team.create!(name: "Arsenal") }
  let(:away_team) { Team.create!(name: "Chelsea") }

  def create_match(**overrides)
    Match.create!(
      {
        competition: competition,
        season: season,
        home_team: home_team,
        away_team: away_team,
        kickoff_at: Time.utc(2024, 8, 17, 15, 0),
        status: "scheduled",
      }.merge(overrides)
    )
  end

  describe "GET /api/v1/matches" do
    it "responds with HTTP 200" do
      get "/api/v1/matches"

      expect(response).to have_http_status(:ok)
    end

    it "returns JSON" do
      get "/api/v1/matches"

      expect(response.media_type).to eq("application/json")
    end

    it "returns an empty array when no matches exist" do
      get "/api/v1/matches"

      expect(JSON.parse(response.body)).to eq([])
    end

    it "exposes the documented public fields for a scheduled fixture" do
      match = create_match

      get "/api/v1/matches"

      expect(JSON.parse(response.body)).to eq(
        [
          {
            "id" => match.id,
            "competition_id" => competition.id,
            "season_id" => season.id,
            "home_team_id" => home_team.id,
            "away_team_id" => away_team.id,
            "kickoff_at" => match.kickoff_at.utc.iso8601,
            "status" => "scheduled",
            "home_score" => nil,
            "away_score" => nil,
          },
        ]
      )
    end

    it "exposes the final result of a completed match" do
      match = create_match(status: "completed", home_score: 2, away_score: 1)

      get "/api/v1/matches"

      body = JSON.parse(response.body).first
      expect(body["id"]).to eq(match.id)
      expect(body["status"]).to eq("completed")
      expect(body["home_score"]).to eq(2)
      expect(body["away_score"]).to eq(1)
    end

    it "returns all persisted matches" do
      create_match(kickoff_at: Time.utc(2024, 8, 17, 15, 0))
      create_match(kickoff_at: Time.utc(2024, 8, 18, 15, 0))

      get "/api/v1/matches"

      expect(JSON.parse(response.body).size).to eq(2)
    end

    it "orders results by kickoff time ascending" do
      late = create_match(kickoff_at: Time.utc(2024, 9, 1, 15, 0))
      early = create_match(kickoff_at: Time.utc(2024, 8, 1, 15, 0))
      middle = create_match(kickoff_at: Time.utc(2024, 8, 15, 15, 0))

      get "/api/v1/matches"

      expect(JSON.parse(response.body).map { |m| m["id"] }).to eq(
        [early.id, middle.id, late.id]
      )
    end

    it "uses the id as a deterministic tie-breaker for equal kickoff times" do
      first = create_match(kickoff_at: Time.utc(2024, 8, 17, 15, 0))
      second = create_match(
        kickoff_at: Time.utc(2024, 8, 17, 15, 0),
        home_team: away_team,
        away_team: Team.create!(name: "Liverpool"),
      )

      get "/api/v1/matches"

      expect(JSON.parse(response.body).map { |m| m["id"] }).to eq([first.id, second.id])
    end

    it "does not require scores for a postponed fixture" do
      match = create_match(status: "postponed")

      get "/api/v1/matches"

      body = JSON.parse(response.body).first
      expect(body["id"]).to eq(match.id)
      expect(body["status"]).to eq("postponed")
      expect(body["home_score"]).to be_nil
      expect(body["away_score"]).to be_nil
    end

    it "does not mutate the database" do
      create_match

      expect { get "/api/v1/matches" }.not_to change(Match, :count)
    end
  end
end
