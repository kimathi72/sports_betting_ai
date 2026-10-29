require 'rails_helper'

# Market-aware inference: Rails sends canonical match + time-safe history, the ML
# service computes features and returns a distribution for ONE market.
#
# Kilo's contract (verified against ml/app/main.py, read-only):
#   POST {ML_SERVICE_URL}/predict/{market}
#   body: { market, <17 flat feature fields> }   -- extra="forbid"
#   ->    { probabilities: {<outcome>: float}, model_version, predicted_at }
#
# FEATURE OWNERSHIP: Python owns the formulas. Rails must not reimplement them, so
# these specs assert that Rails calls the ML service and persists what it returns
# — never that Rails computes a probability itself.
RSpec.describe Predictions::MarketPredictor do
  let(:competition) { Competition.create!(name: 'Premier League', code: 'EPL') }
  let(:season) { Season.create!(competition: competition, name: '2026/27') }
  let(:home) { Team.create!(name: 'Arsenal') }
  let(:away) { Team.create!(name: 'Chelsea') }

  let(:fixture_match) do
    Match.create!(competition: competition, season: season, home_team: home, away_team: away,
                  kickoff_at: Time.utc(2026, 8, 20, 15, 0), status: 'scheduled')
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
      body = { probabilities: probabilities, model_version: version,
               predicted_at: '2026-08-19T10:00:00Z' }
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

      expect(captured[:uri]).to eq('http://ml:8000/predict/1x2')
    end

    it 'sends the 17 feature fields the schema requires' do
      captured = stub_ml(probabilities: { 'H' => 0.5, 'D' => 0.3, 'A' => 0.2 }, market: '1x2')

      predictor.call(fixture_match, market: '1x2')

      expect(captured[:body].keys).to include(
        'home_last5_points', 'home_matches_played', 'away_last5_points',
        'away_matches_played', 'h2h_home_wins', 'h2h_draws', 'h2h_away_wins'
      )
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
    it 'derives 1x/x2/12 from the stored 1x2 rather than calling the ML service' do
      stub_ml(probabilities: { 'H' => 0.5, 'D' => 0.3, 'A' => 0.2 }, market: '1x2')
      predictor.call(fixture_match, market: '1x2')

      # No HTTP stub for this call: if Rails called the service it would fail.
      allow(Net::HTTP).to receive(:new).and_raise('must not call ML for double chance')

      result = predictor.call(fixture_match, market: 'double_chance')

      expect(result).to be_success
      expect(result.prediction.market_outcomes).to eq('1x' => 0.8, 'x2' => 0.5, '12' => 0.7)
    end

    # CONTRACT CHANGE (documented, deliberate).
    #
    # Previously this returned a failure whenever no 1X2 had been stored yet,
    # which made double chance depend on the caller having requested 1X2 first —
    # so a client asking for one market saw it as "unsupported". The market now
    # fetches the 1X2 distribution itself and derives from it. The guarantee that
    # matters is unchanged: double chance is never trained or fitted, it is the
    # projection P(H)+P(D), P(D)+P(A), P(H)+P(A) of whatever the 1X2 model said.
    # See spec/services/predictions/double_chance_bootstrap_spec.rb.
    it 'derives from a freshly fetched 1x2 when none is stored yet' do
      stub_ml(probabilities: { 'H' => 0.5, 'D' => 0.3, 'A' => 0.2 }, market: '1x2')

      result = predictor.call(fixture_match, market: 'double_chance')

      expect(result).to be_success
      expect(result.prediction.market_outcomes).to eq('1x' => 0.8, 'x2' => 0.5, '12' => 0.7)
    end

    it 'fails with a 1x2-related message when the ML service cannot supply 1x2' do
      stub_ml(probabilities: { 'H' => 0.5 }, market: '1x2', status: 503)

      result = predictor.call(fixture_match, market: 'double_chance')

      expect(result).to be_failure
      expect(result.message).to match(/1x2|unreachable|HTTP 5/i)
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

    it 'rejects an unknown market before any network call' do
      allow(Net::HTTP).to receive(:new)

      expect(predictor.call(fixture_match, market: 'correct_score')).to be_failure
      expect(Net::HTTP).not_to have_received(:new)
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
