require 'rails_helper'

# Double chance must be a projection of 1X2, and it must work on its own.
#
# Before this fix, asking for double chance on a match with no stored 1X2
# returned "double chance requires a stored 1x2 prediction" — i.e. the market
# only worked if the caller happened to request 1X2 first. A client that asks
# for exactly one market (the mobile app, a scheduled job) would see the market
# as unsupported for reasons that have nothing to do with the market.
#
# The rule that must not be broken while fixing it: double chance is never
# trained. It is derived from the 1X2 distribution, so the only model involved is
# the 1X2 model, and the derived probabilities must equal the projection of
# whatever that model returned.
RSpec.describe Predictions::MarketPredictor, 'double chance without a stored 1x2' do
  let(:competition) { Competition.create!(name: 'Premier League', code: 'EPL') }
  let(:season) { Season.create!(competition: competition, name: '2026/27') }
  let(:home) { Team.create!(name: 'Arsenal') }
  let(:away) { Team.create!(name: 'Chelsea') }

  let(:fixture_match) do
    Match.create!(competition: competition, season: season, home_team: home, away_team: away,
                  kickoff_at: 3.days.from_now, status: 'scheduled')
  end

  def stub_ml(probabilities:, status: 200, market: 'double_chance')
    http = instance_double(Net::HTTP)
    allow(http).to receive(:open_timeout=)
    allow(http).to receive(:read_timeout=)
    allow(http).to receive(:use_ssl=)
    allow(http).to receive(:start).and_yield(http)

    requested = []
    allow(http).to receive(:request) do |request|
      requested << request.uri.to_s
      body = { market: market, probabilities: probabilities, model_version: 'v-dc',
               predicted_at: '2026-08-19T10:00:00Z', feature_version: 'v2' }
      instance_double(Net::HTTPResponse, code: status.to_s, body: JSON.generate(body))
    end
    allow(Net::HTTP).to receive(:new).and_return(http)
    requested
  end

  let(:predictor) { described_class.new(service_url: 'http://ml:8000') }

  it 'asks the service to derive double chance rather than commissioning a 1x2' do
    # CONTRACT CHANGE (deliberate, documented). Rails used to fetch a 1x2 and
    # project it itself, which meant P(1X) was computed in Ruby as well as in
    # Python. The projection now lives only in the service: one implementation,
    # so the two sides can never disagree about a double chance price.
    requested = stub_ml(probabilities: { '1X' => 0.8, 'X2' => 0.5, '12' => 0.7 })
    result = predictor.call(fixture_match, market: 'double_chance')
    expect(result).to be_success
    expect(requested).to eq(['http://ml:8000/predict/from-history/double_chance'])
  end

  it 'stores the distribution the service projected' do
    stub_ml(probabilities: { '1X' => 0.8, 'X2' => 0.5, '12' => 0.7 })
    predictor.call(fixture_match, market: 'double_chance')
    double_chance = Prediction.find_by(match: fixture_match, market: 'double_chance')
    expect(double_chance.outcomes).to include('1x' => 0.8, 'x2' => 0.5, '12' => 0.7)
    expect(double_chance.model_version).to eq('v-dc')
  end

  it 'stores one live double chance per match, not one per request' do
    stub_ml(probabilities: { '1X' => 0.8, 'X2' => 0.5, '12' => 0.7 })
    predictor.call(fixture_match, market: 'double_chance')
    predictor.call(fixture_match, market: 'double_chance')
    expect(Prediction.current.where(match: fixture_match, market: 'double_chance').count).to eq(1)
  end

  it 'does not require a 1x2 to be commissioned first' do
    stub_ml(probabilities: { '1X' => 0.85, 'X2' => 0.4, '12' => 0.75 })
    result = predictor.call(fixture_match, market: 'double_chance')
    expect(result).to be_success
    expect(Prediction.where(match: fixture_match, market: '1x2')).to be_empty
  end

  it 'reports the service failure rather than inventing a distribution' do
    stub_ml(probabilities: { 'H' => 0.5 }, status: 503)
    result = predictor.call(fixture_match, market: 'double_chance')
    expect(result).not_to be_success
    expect(result.transient?).to be(false), 'a missing model is not an outage; retrying will not help'
    expect(Prediction.where(match: fixture_match, market: 'double_chance')).to be_empty
  end

  it 'still refuses a completed match' do
    completed = Match.create!(competition: competition, season: season, home_team: home,
                              away_team: away, kickoff_at: Time.utc(2026, 7, 1, 15, 0),
                              status: 'completed', home_score: 2, away_score: 1)

    result = predictor.call(completed, market: 'double_chance')

    expect(result).not_to be_success
    expect(result.message).to match(/completed/i)
  end
end
