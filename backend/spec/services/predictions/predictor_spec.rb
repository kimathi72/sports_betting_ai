require "rails_helper"
require "net/http"

# Requests one prediction for one match from the FastAPI ML service, then stores
# it.
#
# The ML service is stubbed at the Net::HTTP seam (the same approach the CSV
# downloader uses): these specs must never require a running model server.
#
# The contract being honoured is Kilo's, not one invented here:
#   POST {ML_SERVICE_URL}/predict
#   { "match": {...}, "history": [...], "competition": "...", "season": "..." }
#   -> { "probabilities": {"H": x, "D": y, "A": z}, "model_version": "...", "predicted_at": "..." }
RSpec.describe Predictions::Predictor do
  let(:competition) { Competition.create!(name: "Premier League", code: "EPL") }
  let(:season) { Season.create!(competition: competition, name: "2026/27") }
  let(:home) { Team.create!(name: "Arsenal") }
  let(:away) { Team.create!(name: "Chelsea") }

  let(:fixture_match) do
    Match.create!(competition: competition, season: season, home_team: home, away_team: away,
                  kickoff_at: Time.utc(2026, 8, 20, 15, 0), status: "scheduled")
  end

  def ml_response(body, status: 200)
    response = instance_double(Net::HTTPResponse, code: status.to_s, body: JSON.generate(body))
    response
  end

  def stub_ml(response: nil, &handler)
    http = instance_double(Net::HTTP)
    allow(http).to receive(:open_timeout=)
    allow(http).to receive(:read_timeout=)
    allow(http).to receive(:use_ssl=)
    allow(http).to receive(:start).and_yield(http)
    allow(http).to receive(:request) do |request|
      handler ? handler.call(request) : response
    end
    allow(Net::HTTP).to receive(:new).and_return(http)
    http
  end

  let(:ok_body) do
    {
      "probabilities" => { "H" => 0.55, "D" => 0.25, "A" => 0.20 },
      "model_version" => "logreg-v1",
      "predicted_at" => "2026-08-19T10:00:00Z",
    }
  end

  def predictor(url: "http://ml:8000")
    described_class.new(service_url: url)
  end

  describe "a successful prediction" do
    it "stores a prediction for the match" do
      stub_ml(response: ml_response(ok_body))

      result = predictor.call(fixture_match)

      expect(result).to be_success
      expect(result.prediction).to be_persisted
      expect(result.prediction.match_id).to eq(fixture_match.id)
    end

    it "maps H/D/A onto home/draw/away probabilities" do
      stub_ml(response: ml_response(ok_body))

      prediction = predictor.call(fixture_match).prediction

      expect(prediction.home_probability.to_f).to be_within(1e-6).of(0.55)
      expect(prediction.draw_probability.to_f).to be_within(1e-6).of(0.25)
      expect(prediction.away_probability.to_f).to be_within(1e-6).of(0.20)
    end

    it "records the model version returned by the service" do
      stub_ml(response: ml_response(ok_body))

      expect(predictor.call(fixture_match).prediction.model_version).to eq("logreg-v1")
    end

    it "records when the prediction was generated" do
      stub_ml(response: ml_response(ok_body))

      expect(predictor.call(fixture_match).prediction.generated_at).to be_present
    end

    it "keeps the feature vector and model metadata for audit" do
      stub_ml(response: ml_response(ok_body))

      prediction = predictor.call(fixture_match).prediction

      expect(prediction.model_metadata).to include("service_url" => "http://ml:8000")
      expect(prediction.features).to be_a(Hash)
    end
  end

  describe "the request it sends" do
    it "posts to /predict on the configured service" do
      http = stub_ml(response: ml_response(ok_body))

      predictor.call(fixture_match)

      expect(http).to have_received(:request) do |request|
        expect(request).to be_a(Net::HTTP::Post)
        expect(request.uri.to_s).to eq("http://ml:8000/predict")
        expect(request["Content-Type"]).to include("application/json")
      end
    end

    it "sends the match, competition, season and time-safe history" do
      http = stub_ml(response: ml_response(ok_body))
      captured = nil
      allow(http).to receive(:request) do |request|
        captured = JSON.parse(request.body)
        ml_response(ok_body)
      end

      predictor.call(fixture_match)

      expect(captured).to include("match", "history", "competition", "season")
      expect(captured["match"]).to include("id" => fixture_match.id, "home_team_id" => home.id)
      expect(captured["competition"]).to eq("Premier League")
      expect(captured["season"]).to eq("2026/27")
    end

    it "sends only history strictly before the fixture" do
      http = stub_ml(response: ml_response(ok_body))
      captured = nil
      allow(http).to receive(:request) do |request|
        captured = JSON.parse(request.body)
        ml_response(ok_body)
      end

      predictor.call(fixture_match)

      kickoffs = captured["history"].map { |m| Time.parse(m["kickoff_at"]) }
      expect(kickoffs).to all(be < fixture_match.kickoff_at)
    end

    it "uses a finite timeout" do
      http = stub_ml(response: ml_response(ok_body))

      predictor.call(fixture_match)

      expect(http).to have_received(:open_timeout=).with(described_class::OPEN_TIMEOUT)
      expect(http).to have_received(:read_timeout=).with(described_class::READ_TIMEOUT)
    end
  end

  describe "refusals before any network call" do
    it "refuses to predict a completed match" do
      fixture_match.update!(status: "completed", home_score: 2, away_score: 1)
      allow(Net::HTTP).to receive(:new)

      result = predictor.call(fixture_match)

      expect(result).to be_failure
      expect(result.message).to match(/completed|result/i)
      expect(Net::HTTP).not_to have_received(:new)
      expect(Prediction.count).to eq(0)
    end

    it "reports a misconfigured service URL rather than guessing one" do
      result = predictor(url: "").call(fixture_match)

      expect(result).to be_failure
      expect(result.message).to match(/url|configured/i)
    end
  end

  describe "failure handling" do
    it "reports an HTTP error without storing anything" do
      stub_ml(response: ml_response({ "detail" => "model not loaded" }, status: 503))

      result = predictor.call(fixture_match)

      expect(result).to be_failure
      expect(result.message).to match(/503|unavailable|model/i)
      expect(Prediction.count).to eq(0)
    end

    it "rejects a response whose probabilities do not sum to 1" do
      bad = ok_body.merge("probabilities" => { "H" => 0.9, "D" => 0.9, "A" => 0.9 })
      stub_ml(response: ml_response(bad))

      result = predictor.call(fixture_match)

      expect(result).to be_failure
      expect(Prediction.count).to eq(0)
    end

    it "rejects a response missing a probability" do
      bad = ok_body.merge("probabilities" => { "H" => 0.5, "D" => 0.5 })
      stub_ml(response: ml_response(bad))

      expect(predictor.call(fixture_match)).to be_failure
    end

    it "rejects a response with no model version" do
      bad = ok_body.except("model_version")
      stub_ml(response: ml_response(bad))

      expect(predictor.call(fixture_match)).to be_failure
    end

    it "reports a connection failure as a transient problem" do
      stub_ml { |_request| raise Errno::ECONNREFUSED }

      result = predictor.call(fixture_match)

      expect(result).to be_failure
      expect(result.transient?).to be(true)
    end

    it "does not leak a stack trace or internal detail in the error" do
      stub_ml { |_request| raise Errno::ECONNREFUSED }

      expect(predictor.call(fixture_match).message).not_to match(/\.rb:\d+|backtrace/i)
    end
  end

  describe "superseding" do
    it "replaces the previous current prediction for the match" do
      stub_ml(response: ml_response(ok_body))
      first = predictor.call(fixture_match).prediction

      second_body = ok_body.merge("probabilities" => { "H" => 0.4, "D" => 0.3, "A" => 0.3 })
      stub_ml(response: ml_response(second_body))
      second = predictor.call(fixture_match).prediction

      expect(first.reload).to be_superseded
      expect(second).not_to be_superseded
      expect(Prediction.where(match_id: fixture_match.id).count).to eq(2)
    end
  end
end
