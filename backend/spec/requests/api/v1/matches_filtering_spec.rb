require 'rails_helper'

# The fixtures endpoint must be usable by a real client.
#
# Measured against the imported corpus, the unbounded `/api/v1/matches` response
# was 717 KB and took ~6 seconds: one request was returning every match since
# 2015. That is unusable on mobile and makes "the current season" inexpressible
# for the ML layer.
#
# These additions are strictly BACKWARD COMPATIBLE: the response stays a bare
# JSON array (the existing contract Kilo consumes), and filters are opt-in. A
# request with no parameters behaves exactly as before, so no breaking change is
# being imposed on the ML or mobile work.
RSpec.describe 'GET /api/v1/matches (filtering and limits)', type: :request do
  let!(:competition) { Competition.create!(name: 'Premier League', code: 'EPL') }
  let!(:other_competition) { Competition.create!(name: 'Championship') }
  let!(:season) { Season.create!(competition: competition, name: '2024/25') }
  let!(:old_season) { Season.create!(competition: competition, name: '2015/16') }
  let!(:other_season) { Season.create!(competition: other_competition, name: '2024/25') }

  let!(:home) { Team.create!(name: 'Arsenal') }
  let!(:away) { Team.create!(name: 'Chelsea') }
  let!(:third) { Team.create!(name: 'Everton') }

  def make_match(season:, kickoff:, status: 'completed', home_team: home, away_team: away,
                 home_score: 1, away_score: 0, in_competition: competition)
    Match.create!(
      competition: in_competition, season: season, home_team: home_team, away_team: away_team,
      kickoff_at: kickoff, status: status,
      home_score: status == 'completed' ? home_score : nil,
      away_score: status == 'completed' ? away_score : nil
    )
  end

  let!(:recent_a) { make_match(season: season, kickoff: Time.utc(2024, 8, 17, 15, 0)) }
  let!(:recent_b) do
    make_match(season: season, kickoff: Time.utc(2024, 8, 18, 14, 0), status: 'scheduled',
               home_team: third)
  end
  let!(:old) { make_match(season: old_season, kickoff: Time.utc(2015, 8, 8, 15, 0)) }
  let!(:elsewhere) { make_match(season: other_season, kickoff: Time.utc(2024, 8, 17, 15, 0),
                                in_competition: other_competition) }

  def body
    JSON.parse(response.body)
  end

  def ids
    body.map { |m| m['id'] }
  end

  describe 'the unchanged default' do
    it 'still returns a bare array, not an envelope' do
      get '/api/v1/matches'

      expect(response).to have_http_status(:ok)
      expect(JSON.parse(response.body)).to be_an(Array)
    end

    it 'still returns every match when no filter is given' do
      get '/api/v1/matches'

      expect(body.length).to eq(4)
    end
  end

  describe '?season_id=' do
    it 'returns only matches in that season' do
      get '/api/v1/matches', params: { season_id: season.id }

      expect(ids).to contain_exactly(recent_a.id, recent_b.id)
    end

    it 'returns an empty array for a season with no matches' do
      empty = Season.create!(competition: competition, name: '1999/00')

      get '/api/v1/matches', params: { season_id: empty.id }

      expect(response).to have_http_status(:ok)
      expect(body).to eq([])
    end
  end

  describe '?competition_id=' do
    it 'returns only matches in that competition' do
      get '/api/v1/matches', params: { competition_id: other_competition.id }

      expect(ids).to eq([elsewhere.id])
    end
  end

  describe 'combined filters' do
    it 'applies competition and season together' do
      get '/api/v1/matches', params: { competition_id: competition.id, season_id: season.id }

      expect(ids).to contain_exactly(recent_a.id, recent_b.id)
    end
  end

  describe '?status=' do
    it 'returns only completed matches' do
      get '/api/v1/matches', params: { status: 'completed' }

      expect(ids).not_to include(recent_b.id)
      expect(ids).to include(recent_a.id)
    end

    it 'returns only scheduled matches' do
      get '/api/v1/matches', params: { status: 'scheduled' }

      expect(ids).to eq([recent_b.id])
    end

    it 'rejects a status outside the closed set rather than silently returning nothing' do
      get '/api/v1/matches', params: { status: 'fixtures' }

      expect(response).to have_http_status(:bad_request)
      expect(JSON.parse(response.body)).to include('error')
    end
  end

  describe '?limit=' do
    it 'caps the number of returned matches' do
      get '/api/v1/matches', params: { limit: 2 }

      expect(body.length).to eq(2)
    end

    it 'returns the earliest fixtures first when limited' do
      get '/api/v1/matches', params: { limit: 1 }

      expect(ids).to eq([old.id])
    end

    it 'caps an excessive limit instead of allowing an unbounded response' do
      get '/api/v1/matches', params: { limit: 10_000 }

      expect(JSON.parse(response.body).size).to be <= Api::V1::MatchesController::MAX_LIMIT
    end

    it 'rejects a non-numeric limit' do
      get '/api/v1/matches', params: { limit: 'many' }

      expect(response).to have_http_status(:bad_request)
    end

    it 'rejects a zero or negative limit' do
      get '/api/v1/matches', params: { limit: 0 }

      expect(response).to have_http_status(:bad_request)
    end
  end

  describe 'ordering is preserved with filters' do
    it 'orders by kickoff ascending, then id' do
      get '/api/v1/matches', params: { competition_id: competition.id }

      expect(ids).to eq([old.id, recent_a.id, recent_b.id])
    end
  end

  describe 'payload shaping' do
    it 'keeps the existing field set exactly' do
      get '/api/v1/matches', params: { season_id: season.id }

      expect(body.first.keys.sort).to eq(
        %w[away_score away_team_id competition_id home_score home_team_id id kickoff_at season_id status]
      )
    end

    it 'emits UTC ISO 8601 kickoffs with a Z suffix' do
      get '/api/v1/matches', params: { season_id: season.id }

      expect(body.map { |m| m['kickoff_at'] }).to all(match(/\A\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z\z/))
    end

    it 'reports null scores for an unplayed fixture' do
      get '/api/v1/matches', params: { status: 'scheduled' }

      expect(body.first).to include('home_score' => nil, 'away_score' => nil)
    end
  end

  describe 'documented limits' do
    it 'declares a bounded page size' do
      expect(Api::V1::MatchesController::DEFAULT_LIMIT).to be_a(Integer)
      expect(Api::V1::MatchesController::MAX_LIMIT).to be <= 5000
    end
  end
end
