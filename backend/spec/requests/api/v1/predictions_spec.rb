require "rails_helper"

# Read endpoints for stored predictions.
#
# These expose what Rails has already persisted. They never trigger inference:
# a GET that called the model would make a read request depend on a second
# service being up, and would let a client generate work by refreshing.
RSpec.describe "GET /api/v1/predictions", type: :request do
  let(:competition) { Competition.create!(name: "Premier League", code: "EPL") }
  let(:season) { Season.create!(competition: competition, name: "2026/27") }
  let(:home) { Team.create!(name: "Arsenal") }
  let(:away) { Team.create!(name: "Chelsea") }

  let(:fixture_match) do
    Match.create!(competition: competition, season: season, home_team: home, away_team: away,
                  kickoff_at: Time.utc(2026, 8, 20, 15, 0), status: "scheduled")
  end

  def create_prediction(overrides = {})
    Prediction.create!(
      {
        match: fixture_match, model_version: "logreg-v1",
        home_probability: 0.5, draw_probability: 0.3, away_probability: 0.2,
        generated_at: Time.utc(2026, 8, 19, 10, 0),
      }.merge(overrides)
    )
  end

  describe "the collection" do
    it "returns an empty array when nothing has been predicted" do
      get "/api/v1/predictions"

      expect(response).to have_http_status(:ok)
      expect(JSON.parse(response.body)).to eq([])
    end

    it "returns stored predictions as a bare array" do
      prediction = create_prediction

      get "/api/v1/predictions"

      expect(JSON.parse(response.body).first["id"]).to eq(prediction.id)
    end

    it "exposes the documented field set" do
      create_prediction

      get "/api/v1/predictions"

      expect(JSON.parse(response.body).first.keys.sort).to eq(
        %w[away_probability draw_probability generated_at home_probability id market
           match_id model_version most_likely_outcome probabilities selection]
      )
    end

    it "returns probabilities as numbers that sum to one" do
      create_prediction

      get "/api/v1/predictions"

      body = JSON.parse(response.body).first
      expect(body["probabilities"].values.sum).to be_within(1e-6).of(1.0)
    end

    it "filters by match_id" do
      create_prediction
      other_match = Match.create!(competition: competition, season: season, home_team: home,
                                  away_team: Team.create!(name: "Everton"),
                                  kickoff_at: Time.utc(2026, 8, 21, 15, 0), status: "scheduled")
      Prediction.create!(match: other_match, model_version: "v1", home_probability: 0.4,
                         draw_probability: 0.3, away_probability: 0.3,
                         generated_at: Time.utc(2026, 8, 19, 11, 0))

      get "/api/v1/predictions", params: { match_id: fixture_match.id }

      expect(JSON.parse(response.body).map { |p| p["match_id"] }).to eq([fixture_match.id])
    end

    it "returns only current predictions by default" do
      create_prediction
      create_prediction(generated_at: Time.utc(2026, 8, 19, 12, 0))

      get "/api/v1/predictions", params: { match_id: fixture_match.id }

      expect(JSON.parse(response.body).length).to eq(1)
    end

    it "can include superseded history when asked" do
      create_prediction
      create_prediction(generated_at: Time.utc(2026, 8, 19, 12, 0))

      get "/api/v1/predictions", params: { match_id: fixture_match.id, include_history: true }

      expect(JSON.parse(response.body).length).to eq(2)
    end
  end

  describe "GET /api/v1/predictions/:match_id" do
    it "returns the current prediction for a match" do
      prediction = create_prediction

      get "/api/v1/predictions/#{fixture_match.id}"

      # CONTRACT CHANGE: `show` now returns every current market for the fixture
      # (a match can hold 1x2, over/under, btts and double chance at once), so the
      # payload is an envelope with a `predictions` array rather than one object.
      expect(response).to have_http_status(:ok)
      body = JSON.parse(response.body)
      expect(body["match_id"]).to eq(fixture_match.id)
      expect(body["predictions"].length).to eq(1)
      expect(body["predictions"].first["market"]).to eq("1x2")
      expect(body["predictions"].first["selection"]).to eq("H")
    end

    it "returns 404 with an error payload when no prediction exists" do
      get "/api/v1/predictions/#{fixture_match.id}"

      expect(response).to have_http_status(:not_found)
      expect(JSON.parse(response.body)).to include("error")
    end

    it "returns 404 for a match that does not exist" do
      get "/api/v1/predictions/999999"

      expect(response).to have_http_status(:not_found)
    end
  end

  describe "GET /api/v1/model_status" do
    it "reports which model versions have produced predictions" do
      create_prediction

      get "/api/v1/model_status"

      expect(response).to have_http_status(:ok)
      body = JSON.parse(response.body)
      expect(body["model_versions"].first).to include("model_version" => "logreg-v1")
    end

    it "reports counts and the latest generation time" do
      create_prediction

      get "/api/v1/model_status"

      body = JSON.parse(response.body)
      expect(body["prediction_count"]).to eq(1)
      expect(body["latest_generated_at"]).to match(/\A\d{4}-\d{2}-\d{2}T/)
    end

    it "is an empty, honest state before any prediction exists" do
      get "/api/v1/model_status"

      body = JSON.parse(response.body)
      expect(body["prediction_count"]).to eq(0)
      expect(body["model_versions"]).to eq([])
      expect(body["latest_generated_at"]).to be_nil
    end
  end
end
