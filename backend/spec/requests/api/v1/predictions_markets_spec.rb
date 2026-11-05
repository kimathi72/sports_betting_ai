require "rails_helper"

# Market-aware prediction endpoints.
#
# A match can hold all four markets at once, so the API must expose them as
# DISTINCT entries rather than one ambiguous "prediction". `show` returns every
# current market for a fixture; the collection can be filtered by market.
#
# Existing behaviour is preserved: the bare-array collection and the legacy
# home/draw/away fields on 1X2 rows still work, so nothing already built against
# this API breaks.
RSpec.describe "GET /api/v1/predictions (markets)", type: :request do
  let(:competition) { Competition.create!(name: "Premier League", code: "EPL") }
  let(:season) { Season.create!(competition: competition, name: "2026/27") }
  let(:home) { Team.create!(name: "Arsenal") }
  let(:away) { Team.create!(name: "Chelsea") }

  let(:fixture_match) do
    Match.create!(competition: competition, season: season, home_team: home, away_team: away,
                  kickoff_at: Time.utc(2026, 8, 20, 15, 0), status: "scheduled")
  end

  def add(market, outcomes, version: "v1", generated_at: Time.utc(2026, 8, 19, 10, 0))
    Prediction.create!(
      match: fixture_match, market: market, model_version: version,
      home_probability: 0, draw_probability: 0, away_probability: 1,
      outcomes: outcomes, generated_at: generated_at,
    )
  end

  def one_x_two
    Prediction.create!(
      match: fixture_match, market: "1x2", model_version: "v1",
      home_probability: 0.5, draw_probability: 0.3, away_probability: 0.2,
      outcomes: { "H" => 0.5, "D" => 0.3, "A" => 0.2 },
      generated_at: Time.utc(2026, 8, 19, 10, 0),
    )
  end

  def body
    JSON.parse(response.body)
  end

  describe "GET /api/v1/predictions/:match_id" do
    it "returns every current market for the match" do
      one_x_two
      add("btts", { "yes" => 0.6, "no" => 0.4 })
      add("over_under_2.5", { "over" => 0.55, "under" => 0.45 })

      get "/api/v1/predictions/#{fixture_match.id}"

      expect(response).to have_http_status(:ok)
      expect(body["match_id"]).to eq(fixture_match.id)
      expect(body["predictions"].map { |p| p["market"] }).to contain_exactly("1x2", "btts", "over_under_2.5")
    end

    it "exposes market, selection, probabilities, model_version and generated_at" do
      one_x_two

      get "/api/v1/predictions/#{fixture_match.id}"

      entry = body["predictions"].first
      expect(entry.keys.sort).to eq(
        %w[generated_at market model_version probabilities selection]
      )
      expect(entry["selection"]).to eq("H")
      expect(entry["probabilities"]).to eq("H" => 0.5, "D" => 0.3, "A" => 0.2)
    end

    it "returns 404 when the match has no predictions at all" do
      get "/api/v1/predictions/#{fixture_match.id}"

      expect(response).to have_http_status(:not_found)
      expect(body).to include("error")
    end
  end

  describe "filtering by market" do
    before do
      one_x_two
      add("btts", { "yes" => 0.6, "no" => 0.4 })
    end

    it "returns only the requested market from the collection" do
      get "/api/v1/predictions", params: { market: "btts" }

      expect(body.map { |p| p["market"] }).to eq(["btts"])
    end

    it "rejects an unsupported market with a validation error" do
      get "/api/v1/predictions", params: { market: "teleportation" }

      expect(response).to have_http_status(:bad_request)
      expect(body["error"]).to match(/market/i)
    end

    it "reports the available markets for a match" do
      get "/api/v1/predictions/#{fixture_match.id}", params: { market: "btts" }

      expect(body["predictions"].map { |p| p["market"] }).to eq(["btts"])
    end
  end

  describe "backwards compatibility" do
    it "still returns a bare array from the collection" do
      one_x_two

      get "/api/v1/predictions"

      expect(body).to be_an(Array)
      expect(body.first).to include("match_id", "model_version", "generated_at")
    end

    it "still exposes legacy 1x2 probability fields" do
      one_x_two

      get "/api/v1/predictions", params: { market: "1x2" }

      expect(body.first).to include(
        "home_probability" => 0.5, "draw_probability" => 0.3, "away_probability" => 0.2,
      )
    end
  end

  describe 'distinguishing "no prediction" from "service failed"' do
    it "uses 404 for a match that simply has no prediction" do
      get "/api/v1/predictions/#{fixture_match.id}"

      expect(response).to have_http_status(:not_found)
    end

    it "uses 400 for an invalid request" do
      get "/api/v1/predictions", params: { market: "nope" }

      expect(response).to have_http_status(:bad_request)
    end
  end
end
