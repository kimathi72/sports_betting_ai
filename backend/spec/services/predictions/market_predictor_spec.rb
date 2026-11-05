require 'rails_helper'

# Market-aware inference: Rails sends canonical match + time-safe history, the ML
# service computes features and returns a distribution for ONE market.
#
# ML contract (verified against ml/app/main.py):
#   POST {ML_SERVICE_URL}/predict/from-history/{market}
#   body: { match: {...}, history: [ {...}, ... ] }
#   ->    { market, probabilities: {<outcome>: float}, model_version, predicted_at,
#           feature_version }
#
# FEATURE OWNERSHIP: Python owns the formulas. An earlier version of this class
# posted a flat 17-field vector it had computed in Ruby; that made two
# implementations of the same maths, which can disagree silently. Rails now sends
# the fixture and its history, and these specs assert exactly that — Rails calls
# the ML service and persists what it returns, and never computes a probability.
RSpec.describe Predictions::MarketPredictor do
  let(:competition) { Competition.create!(name: 'Premier League', code: 'EPL') }
  let(:season) { Season.create!(competition: competition, name: '2026/27') }
  let(:home) { Team.create!(name: 'Arsenal') }
  let(:away) { Team.create!(name: 'Chelsea') }

  # A fixture in the FUTURE. The producer refuses a kickoff that has passed, so a
  # fixed date would silently turn this whole file into a test of the refusal as
  # soon as that date went by.
  let(:fixture_match) do
    Match.create!(competition: competition, season: season, home_team: home, away_team: away,
                  kickoff_at: 3.days.from_now, status: 'scheduled')
  end

  # Captures what Rails actually sends, and replies with a canned distribution.
  def stub_ml(probabilities:, market:, version: 'v1', status: 200)
    http = instance_double(Net::HTTP)
    allow(http).to receive(:open_timeout=)
    allow(http).to receive(:read_timeout=)
    allow(http).to receive(:use_ssl=)
    allow(http).to receive(:start).and_yield(http)

    captured = {}
    allow(http).to receive(:request) do |request|
      captured[:uri] = request.uri.to_s
      captured[:body] = JSON.parse(request.body)
      body = { market: market, probabilities: probabilities, model_version: version,
               predicted_at: '2026-08-19T10:00:00Z', feature_version: 'v2' }
      instance_double(Net::HTTPResponse, code: status.to_s, body: JSON.generate(body))
    end

    allow(Net::HTTP).to receive(:new).and_return(http)
    captured
  end

  def predictor
    described_class.new(service_url: 'http://ml:8000')
  end

  describe '1x2' do
    it 'posts to the market-specific endpoint' do
      captured = stub_ml(probabilities: { 'H' => 0.5, 'D' => 0.3, 'A' => 0.2 }, market: '1x2')

      predictor.call(fixture_match, market: '1x2')

      expect(captured[:uri]).to eq('http://ml:8000/predict/from-history/1x2')
    end

    it 'sends the fixture and its history rather than a locally computed feature vector' do
      captured = stub_ml(probabilities: { 'H' => 0.5, 'D' => 0.3, 'A' => 0.2 }, market: '1x2')

      predictor.call(fixture_match, market: '1x2')

      expect(captured[:body].keys).to contain_exactly('match', 'history')
      expect(captured[:body]['match']).to include(
        'id' => fixture_match.id,
        'home_team_id' => home.id,
        'away_team_id' => away.id,
        'kickoff_at' => fixture_match.kickoff_at.utc.iso8601
      )
    end

    it 'never sends a 17-field feature vector on any market' do
      { '1x2' => { 'H' => 0.5, 'D' => 0.3, 'A' => 0.2 },
        'btts' => { 'Yes' => 0.6, 'No' => 0.4 } }.each do |market, probabilities|
        captured = stub_ml(probabilities: probabilities, market: market)
        predictor.call(fixture_match, market: market)
        expect(captured[:body]).not_to include('home_last5_points')
      end
    end

    it 'persists a 1x2 prediction with canonical H/D/A outcomes' do
      stub_ml(probabilities: { 'H' => 0.5, 'D' => 0.3, 'A' => 0.2 }, market: '1x2')

      result = predictor.call(fixture_match, market: '1x2')

      expect(result).to be_success
      record = result.prediction
      expect(record.market).to eq('1x2')
      expect(record.market_outcomes).to eq('H' => 0.5, 'D' => 0.3, 'A' => 0.2)
      expect(record.selection).to eq('H')
    end

    it 'keeps the legacy home/draw/away columns in step for 1x2' do
      stub_ml(probabilities: { 'H' => 0.5, 'D' => 0.3, 'A' => 0.2 }, market: '1x2')

      record = predictor.call(fixture_match, market: '1x2').prediction

      expect(record.home_probability.to_f).to be_within(1e-6).of(0.5)
      expect(record.draw_probability.to_f).to be_within(1e-6).of(0.3)
      expect(record.away_probability.to_f).to be_within(1e-6).of(0.2)
    end
  end

  describe 'over/under 2.5' do
    it 'persists over/under outcomes without touching the 1x2 prediction' do
      stub_ml(probabilities: { 'H' => 0.5, 'D' => 0.3, 'A' => 0.2 }, market: '1x2')
      predictor.call(fixture_match, market: '1x2')

      stub_ml(probabilities: { 'over' => 0.55, 'under' => 0.45 }, market: 'over_under_2.5')
      result = predictor.call(fixture_match, market: 'over_under_2.5')

      expect(result).to be_success
      expect(result.prediction.market_outcomes).to eq('over' => 0.55, 'under' => 0.45)

      one_x_two = Prediction.current.for_market('1x2').find_by(match_id: fixture_match.id)
      expect(one_x_two).not_to be_superseded
      expect(one_x_two.market_outcomes).to eq('H' => 0.5, 'D' => 0.3, 'A' => 0.2)
    end
  end

  describe 'btts' do
    it 'persists yes/no outcomes' do
      stub_ml(probabilities: { 'yes' => 0.6, 'no' => 0.4 }, market: 'btts')

      record = predictor.call(fixture_match, market: 'btts').prediction

      expect(record.market_outcomes).to eq('yes' => 0.6, 'no' => 0.4)
      expect(record.selection).to eq('yes')
    end
  end

  describe 'double chance' do
    it 'asks the service for the derived distribution and stores it' do
      # Double chance is DERIVED, never fitted: the service is asked for the
      # projection and Rails stores what it returns. Rails no longer computes
      # P(1X) itself, so there is one implementation of the formula.
      captured = stub_ml(probabilities: { '1X' => 0.8, 'X2' => 0.5, '12' => 0.7 }, market: 'double_chance')

      result = predictor.call(fixture_match, market: 'double_chance')

      expect(result).to be_success
      expect(captured[:uri]).to end_with('/predict/from-history/double_chance')
      expect(result.prediction.market_outcomes).to eq('1x' => 0.8, 'x2' => 0.5, '12' => 0.7)
    end

    it 'does not require a stored 1x2 first' do
      stub_ml(probabilities: { '1X' => 0.8, 'X2' => 0.5, '12' => 0.7 }, market: 'double_chance')

      result = predictor.call(fixture_match, market: 'double_chance')

      expect(result).to be_success
      expect(Prediction.current.for_market('double_chance').count).to eq(1)
    end

    it 'fails cleanly when the service has no 1x2 distribution to project' do
      stub_ml(probabilities: { 'H' => 0.5 }, market: 'double_chance', status: 503)

      result = predictor.call(fixture_match, market: 'double_chance')

      expect(result).to be_failure
      expect(result.message).to match(/no model is available/i)
    end
  end

  describe 'correct score' do
    it 'stores the truncated scorelines the service ranked' do
      stub_ml(probabilities: { '2-1' => 0.12, '1-1' => 0.11, '1-0' => 0.10 }, market: 'correct_score')

      result = predictor.call(fixture_match, market: 'correct_score')

      expect(result).to be_success
      expect(result.prediction.outcomes.keys).to eq(%w[2-1 1-1 1-0])
      # A truncated view sums to well under 1; that is correct, not a rounding error.
      expect(result.prediction.outcomes.values.sum).to be < 1.0
    end
  end

  describe 'all four markets coexist' do
    it 'leaves four live predictions for one match' do
      stub_ml(probabilities: { 'H' => 0.5, 'D' => 0.3, 'A' => 0.2 }, market: '1x2')
      predictor.call(fixture_match, market: '1x2')
      stub_ml(probabilities: { 'over' => 0.55, 'under' => 0.45 }, market: 'over_under_2.5')
      predictor.call(fixture_match, market: 'over_under_2.5')
      stub_ml(probabilities: { 'yes' => 0.6, 'no' => 0.4 }, market: 'btts')
      predictor.call(fixture_match, market: 'btts')
      stub_ml(probabilities: { '1X' => 0.8, 'X2' => 0.5, '12' => 0.7 }, market: 'double_chance')
      predictor.call(fixture_match, market: 'double_chance')

      live = Prediction.current.where(match_id: fixture_match.id)
      expect(live.pluck(:market)).to contain_exactly('1x2', 'over_under_2.5', 'btts', 'double_chance')
    end
  end

  describe 'outcome key casing from the ML service' do
    # Verified against the running service: it returns "Over"/"Under" and
    # "Yes"/"No" (capitalised), while Rails stores canonical lower case. Without
    # normalisation every binary-market prediction fails validation.
    it 'accepts capitalised Over/Under and stores canonical lower case' do
      stub_ml(probabilities: { 'Over' => 0.74, 'Under' => 0.26 }, market: 'over_under_2.5')

      result = predictor.call(fixture_match, market: 'over_under_2.5')

      expect(result).to be_success
      expect(result.prediction.market_outcomes).to eq('over' => 0.74, 'under' => 0.26)
    end

    it 'accepts capitalised Yes/No and stores canonical lower case' do
      stub_ml(probabilities: { 'Yes' => 0.45, 'No' => 0.55 }, market: 'btts')

      result = predictor.call(fixture_match, market: 'btts')

      expect(result).to be_success
      expect(result.prediction.market_outcomes).to eq('yes' => 0.45, 'no' => 0.55)
    end

    it 'keeps 1X2 H/D/A upper case' do
      stub_ml(probabilities: { 'H' => 0.5, 'D' => 0.3, 'A' => 0.2 }, market: '1x2')

      expect(predictor.call(fixture_match, market: '1x2').prediction.market_outcomes.keys)
        .to contain_exactly('H', 'D', 'A')
    end
  end

  describe 'response validation' do
    it 'rejects a distribution that does not sum to 1' do
      stub_ml(probabilities: { 'over' => 0.8, 'under' => 0.8 }, market: 'over_under_2.5')

      expect(predictor.call(fixture_match, market: 'over_under_2.5')).to be_failure
      expect(Prediction.count).to eq(0)
    end

    it 'rejects missing outcome keys' do
      stub_ml(probabilities: { 'over' => 1.0 }, market: 'over_under_2.5')

      expect(predictor.call(fixture_match, market: 'over_under_2.5')).to be_failure
    end

    it 'rejects a probability outside 0..1' do
      stub_ml(probabilities: { 'yes' => 1.4, 'no' => -0.4 }, market: 'btts')

      expect(predictor.call(fixture_match, market: 'btts')).to be_failure
    end

    it 'rejects an HTTP error without persisting anything' do
      stub_ml(probabilities: { 'H' => 0.5, 'D' => 0.3, 'A' => 0.2 }, market: '1x2', status: 503)

      result = predictor.call(fixture_match, market: '1x2')

      expect(result).to be_failure
      expect(Prediction.count).to eq(0)
    end

    it 'rejects a market outside the closed set before any network call' do
      allow(Net::HTTP).to receive(:new)

      expect(predictor.call(fixture_match, market: 'teleportation')).to be_failure
      expect(Net::HTTP).not_to have_received(:new)
    end

    it 'rejects correct score lines that are not scorelines' do
      stub_ml(probabilities: { 'lots' => 0.6, 'few' => 0.3 }, market: 'correct_score')

      result = predictor.call(fixture_match, market: 'correct_score')

      expect(result).to be_failure
      expect(Prediction.count).to eq(0)
    end

    it 'rejects correct score lines that claim more than certainty' do
      stub_ml(probabilities: { '2-1' => 0.8, '1-0' => 0.6 }, market: 'correct_score')

      expect(predictor.call(fixture_match, market: 'correct_score')).to be_failure
    end
  end

  describe 'guards' do
    it 'refuses to predict a completed match' do
      fixture_match.update!(status: 'completed', home_score: 2, away_score: 1)

      expect(predictor.call(fixture_match, market: '1x2')).to be_failure
      expect(Prediction.count).to eq(0)
    end

    it 'reports a missing service URL' do
      expect(described_class.new(service_url: '').call(fixture_match, market: '1x2')).to be_failure
    end
  end
end

# Provenance capture for prospective evaluation.
#
# The ML service already returns `feature_version`; Rails used to discard it. Without
# it a prediction cannot be attributed to an identifiable generation, and prospective
# eligibility must reject it.
RSpec.describe Predictions::MarketPredictor, 'prospective provenance' do
  let(:competition) { Competition.create!(name: "Prov League #{SecureRandom.hex(3)}") }
  let(:season) { Season.create!(competition: competition, name: '2026/27') }
  let(:home) { Team.create!(name: "Prov Home #{SecureRandom.hex(3)}") }
  let(:away) { Team.create!(name: "Prov Away #{SecureRandom.hex(3)}") }
  let!(:fixture_match) do
    # A future kickoff: the producer refuses a fixture that has already started.
    Match.create!(competition: competition, season: season, home_team: home, away_team: away,
                  kickoff_at: 2.days.from_now, status: 'scheduled')
  end

  # Uses the same Net::HTTP stub style as the rest of this file.
  def stub_ml_detailed(extra = {})
    http = instance_double(Net::HTTP)
    allow(http).to receive(:open_timeout=)
    allow(http).to receive(:read_timeout=)
    allow(http).to receive(:use_ssl=)
    allow(http).to receive(:start).and_yield(http)
    allow(http).to receive(:request) do
      body = { market: '1x2', probabilities: { 'H' => 0.5, 'D' => 0.3, 'A' => 0.2 },
               model_version: 'v2', predicted_at: '2026-11-07T09:00:00Z',
               feature_version: 'v2' }.merge(extra)
      instance_double(Net::HTTPResponse, code: '200', body: JSON.generate(body))
    end
    allow(Net::HTTP).to receive(:new).and_return(http)
  end

  def run_predictor
    described_class.new(service_url: 'http://ml:8000').call(fixture_match, market: '1x2')
  end

  it 'records the feature version the service reported' do
    stub_ml_detailed
    result = run_predictor

    expect(result.prediction.model_metadata['feature_version']).to eq('v2')
  end

  it 'records the kickoff the fixture had at issue time' do
    stub_ml_detailed
    result = run_predictor

    expect(result.prediction.issued_kickoff_at).to eq(fixture_match.kickoff_at)
  end

  it 'stores the freeze digest when the service supplies one' do
    stub_ml_detailed(model_freeze_digest: 'feedface' * 8)
    result = run_predictor

    expect(result.prediction.model_freeze_digest).to eq('feedface' * 8)
  end

  it 'leaves the digest null when the service does not supply one' do
    stub_ml_detailed
    result = run_predictor

    expect(result.prediction.model_freeze_digest).to be_nil
  end

  it 'passes the digest through unchanged, including its exact value' do
    # Provenance must not be reformatted, truncated or lower-cased: Rails stores it
    # verbatim so it can be matched against the freeze record later.
    stub_ml_detailed(model_freeze_digest: 'AbC123dEf456')
    result = run_predictor

    expect(result.prediction.model_freeze_digest).to eq('AbC123dEf456')
    expect(result.prediction.model_metadata['model_freeze_digest']).to eq('AbC123dEf456')
  end

  it 'leaves the digest missing when the service reports provenance_status unavailable' do
    stub_ml_detailed(provenance_status: 'unavailable')
    result = run_predictor

    expect(result.prediction.model_freeze_digest).to be_nil
  end

  it 'records the digest and feature version for the same response' do
    stub_ml_detailed(model_freeze_digest: 'deadbeef' * 8, feature_version: 'v2')
    result = run_predictor

    expect(result.prediction.model_metadata['feature_version']).to eq('v2')
    expect(result.prediction.model_freeze_digest).to eq('deadbeef' * 8)
  end
end
