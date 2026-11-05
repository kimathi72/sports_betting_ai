require 'rails_helper'
require 'net/http'

# POST /api/v1/predictions — the endpoint that actually requests a prediction.
#
# WHY THIS EXISTS: the API was read-only, so `POST /api/v1/predictions` raised
# ActionController::RoutingError ("No route matches"). Any client trying to
# generate a prediction hit an exception rather than a response.
#
# The endpoint is a thin orchestration layer over Predictions::MarketPredictor; it
# contains no probability maths. The ML service is stubbed here, because these
# specs must run without a live model server.
RSpec.describe 'POST /api/v1/predictions', type: :request do
  let(:competition) { Competition.create!(name: 'Premier League', code: 'EPL') }
  let(:season) { Season.create!(competition: competition, name: '2026/27') }
  let(:home) { Team.create!(name: 'Arsenal') }
  let(:away) { Team.create!(name: 'Chelsea') }

  let(:fixture_match) do
    # A FUTURE kickoff. The producer refuses a fixture whose kickoff has passed
    # (a stale `scheduled` row is not predictable either), so a hard-coded date
    # would quietly turn these specs into tests of the refusal.
    Match.create!(competition: competition, season: season, home_team: home, away_team: away,
                  kickoff_at: 2.days.from_now, status: 'scheduled')
  end

  def body
    JSON.parse(response.body)
  end

  # Answers with ``probabilities`` for the requested market and reports that
  # market's name back. Reporting it lets the predictor prove the service answered
  # the market that was asked for, so a stub cannot quietly cover for a routing bug.
  def stub_ml(probabilities:, status: 200)
    http = instance_double(Net::HTTP)
    allow(http).to receive(:open_timeout=)
    allow(http).to receive(:read_timeout=)
    allow(http).to receive(:use_ssl=)
    allow(http).to receive(:start).and_yield(http)
    allow(http).to receive(:request) do |request|
      market = request.path.split('/').last
      instance_double(Net::HTTPResponse, code: status.to_s,
                                         body: JSON.generate(probabilities: probabilities,
                                                             market: market,
                                                             model_version: 'v0.3.0',
                                                             predicted_at: '2026-08-19T10:00:00Z'))
    end
    allow(Net::HTTP).to receive(:new).and_return(http)
  end

  before do
    stub_const('ENV', ENV.to_h.merge('ML_SERVICE_URL' => 'http://ml:8000'))
  end

  describe 'a successful 1x2 request' do
    before { stub_ml(probabilities: { 'H' => 0.5, 'D' => 0.3, 'A' => 0.2 }) }

    it 'creates the prediction and returns 201' do
      post '/api/v1/predictions', params: { match_id: fixture_match.id, markets: ['1x2'] }, as: :json

      expect(response).to have_http_status(:created)
      expect(body['match_id']).to eq(fixture_match.id)
      expect(body['predictions'].first['market']).to eq('1x2')
    end

    it 'persists exactly one prediction' do
      expect {
        post '/api/v1/predictions', params: { match_id: fixture_match.id, markets: ['1x2'] }, as: :json
      }.to change(Prediction, :count).by(1)
    end

    it 'returns the probabilities it stored' do
      post '/api/v1/predictions', params: { match_id: fixture_match.id, markets: ['1x2'] }, as: :json

      expect(body['predictions'].first['probabilities']).to eq('H' => 0.5, 'D' => 0.3, 'A' => 0.2)
    end
  end

  describe 'several markets in one request' do
    before do
      # Each market has its OWN distribution: 1x2 is three-way, double chance is the
      # projection. A single three-outcome stub cannot answer both, and a service
      # that returned the 1X2 body for a double chance request would be a bug these
      # examples must catch rather than hide.
      allow(Net::HTTP).to receive(:new) do
        http = instance_double(Net::HTTP)
        allow(http).to receive(:open_timeout=); allow(http).to receive(:read_timeout=)
        allow(http).to receive(:use_ssl=); allow(http).to receive(:start).and_yield(http)
        allow(http).to receive(:request) do |request|
          market = request.path.split('/').last
          payload = market == 'double_chance' ? { '1X' => 0.8, 'X2' => 0.5, '12' => 0.7 } : { 'H' => 0.5, 'D' => 0.3, 'A' => 0.2 }
          instance_double(Net::HTTPResponse, code: '200',
                                             body: JSON.generate(probabilities: payload, market: market,
                                                                 model_version: 'v0.3.0',
                                                                 predicted_at: '2026-08-19T10:00:00Z'))
        end
        http
      end
    end

    it 'creates one prediction per requested market' do
      post '/api/v1/predictions',
           params: { match_id: fixture_match.id, markets: %w[1x2 double_chance] }, as: :json

      expect(response).to have_http_status(:created)
      expect(body['predictions'].map { |p| p['market'] }).to contain_exactly('1x2', 'double_chance')
    end

    it 'returns the derived double chance the service projected' do
      post '/api/v1/predictions',
           params: { match_id: fixture_match.id, markets: %w[1x2 double_chance] }, as: :json

      dc = body['predictions'].find { |p| p['market'] == 'double_chance' }
      expect(dc['probabilities']).to eq('1x' => 0.8, 'x2' => 0.5, '12' => 0.7)
    end
  end

  describe 'partial failure' do
    it 'keeps successful markets when another market fails' do
      # Make the failure market-specific rather than call-order specific.
      allow(Net::HTTP).to receive(:new) do |host, port|
        http = instance_double(Net::HTTP)
        allow(http).to receive(:open_timeout=); allow(http).to receive(:read_timeout=)
        allow(http).to receive(:use_ssl=); allow(http).to receive(:start).and_yield(http)
        allow(http).to receive(:request) do |request|
          raise Errno::ECONNREFUSED if request.path.include?('/btts')

          instance_double(Net::HTTPResponse, code: '200',
                                             body: JSON.generate(probabilities: { 'H' => 0.5, 'D' => 0.3, 'A' => 0.2 },
                                                                 model_version: 'v', predicted_at: nil))
        end
        http
      end

      post '/api/v1/predictions',
           params: { match_id: fixture_match.id, markets: %w[1x2 btts] }, as: :json

      expect(response).to have_http_status(:multi_status)
      expect(body['predictions'].map { |p| p['market'] }).to eq(['1x2'])
      expect(body['errors'].keys).to eq(['btts'])
    end
  end

  describe 'validation errors' do
    it 'returns 404 for an unknown match' do
      post '/api/v1/predictions', params: { match_id: 999_999, markets: ['1x2'] }, as: :json

      expect(response).to have_http_status(:not_found)
      expect(body['error']).to match(/match/i)
    end

    it 'returns 422 for a completed match, which cannot be predicted' do
      fixture_match.update!(status: 'completed', home_score: 2, away_score: 1)

      post '/api/v1/predictions', params: { match_id: fixture_match.id, markets: ['1x2'] }, as: :json

      expect(response).to have_http_status(:unprocessable_entity)
      expect(Prediction.count).to eq(0)
    end

    it 'returns 400 for an unsupported market' do
      post '/api/v1/predictions',
           params: { match_id: fixture_match.id, markets: ['teleportation'] }, as: :json

      expect(response).to have_http_status(:bad_request)
      expect(body['error']).to match(/market/i)
    end

    it 'returns 400 when no market is given' do
      post '/api/v1/predictions', params: { match_id: fixture_match.id }, as: :json

      expect(response).to have_http_status(:bad_request)
    end

    it 'returns 400 when match_id is missing' do
      post '/api/v1/predictions', params: { markets: ['1x2'] }, as: :json

      expect(response).to have_http_status(:bad_request)
    end
  end

  describe 'service failures' do
    it 'returns 503 when the ML service is unreachable, and stores nothing' do
      allow(Net::HTTP).to receive(:new) do
        http = instance_double(Net::HTTP)
        allow(http).to receive(:open_timeout=); allow(http).to receive(:read_timeout=)
        allow(http).to receive(:use_ssl=); allow(http).to receive(:start).and_yield(http)
        allow(http).to receive(:request).and_raise(Errno::ECONNREFUSED)
        http
      end

      post '/api/v1/predictions', params: { match_id: fixture_match.id, markets: ['1x2'] }, as: :json

      expect(response).to have_http_status(:service_unavailable)
      expect(Prediction.count).to eq(0)
    end

    it 'does not leak a stack trace in the error payload' do
      allow(Net::HTTP).to receive(:new).and_raise(Errno::ECONNREFUSED)

      post '/api/v1/predictions', params: { match_id: fixture_match.id, markets: ['1x2'] }, as: :json

      expect(response.body).not_to match(/\.rb:\d+|backtrace/i)
    end
  end
end
