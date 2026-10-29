require 'rails_helper'

# Seasons, discoverable without hardcoding database ids.
#
# The ML training flow previously hardcoded season ids (15, 8, ... 4). Those
# happen to match today's database but are not stable: re-importing history
# renumbers them, and a training run would then silently fetch the wrong seasons
# — or none at all. A consumer must be able to ASK which seasons exist.
#
# The response therefore carries enough to drive per-season retrieval: the id, the
# label, the competition, and the match counts, so a client can tell a complete
# season from an in-progress one without guessing.
RSpec.describe 'GET /api/v1/seasons', type: :request do
  let(:competition) { Competition.create!(name: 'Premier League', code: 'EPL') }
  let(:other) { Competition.create!(name: 'Championship') }
  let(:home) { Team.create!(name: 'Arsenal') }
  let(:away) { Team.create!(name: 'Chelsea') }

  let!(:season_2025) { Season.create!(competition: competition, name: '2025/26') }
  let!(:season_2024) { Season.create!(competition: competition, name: '2024/25') }
  let!(:championship) { Season.create!(competition: other, name: '2024/25') }

  def add_match(season:, status: 'completed', kickoff: Time.utc(2025, 8, 15, 15, 0))
    Match.create!(competition: season.competition, season: season, home_team: home,
                  away_team: away, kickoff_at: kickoff, status: status,
                  home_score: status == 'completed' ? 1 : nil,
                  away_score: status == 'completed' ? 0 : nil)
  end

  def body
    JSON.parse(response.body)
  end

  describe 'the collection' do
    before do
      2.times { |i| add_match(season: season_2025, kickoff: Time.utc(2025, 8, 15 + i, 15, 0)) }
      add_match(season: season_2025, status: 'scheduled', kickoff: Time.utc(2026, 5, 1, 15, 0))
    end

    it 'returns a bare array' do
      get '/api/v1/seasons'

      expect(response).to have_http_status(:ok)
      expect(body).to be_an(Array)
    end

    it 'returns every season' do
      get '/api/v1/seasons'

      expect(body.map { |s| s['id'] }).to contain_exactly(
        season_2025.id, season_2024.id, championship.id
      )
    end

    it 'exposes a stable field set' do
      get '/api/v1/seasons'

      expect(body.first.keys.sort).to eq(
        %w[competition_id completed_match_count id match_count name]
      )
    end

    it 'reports match counts so a client can spot an in-progress season' do
      get '/api/v1/seasons'

      season = body.find { |s| s['id'] == season_2025.id }
      expect(season['match_count']).to eq(3)
      expect(season['completed_match_count']).to eq(2)
    end

    it 'orders by competition then season name descending (newest first)' do
      get '/api/v1/seasons'

      expect(body.map { |s| [s['competition_id'], s['name']] }).to eq(
        [[competition.id, '2025/26'], [competition.id, '2024/25'], [other.id, '2024/25']]
      )
    end
  end

  describe 'filtering' do
    before { add_match(season: season_2025) }

    it 'filters by competition_id' do
      get '/api/v1/seasons', params: { competition_id: other.id }

      expect(body.map { |s| s['id'] }).to eq([championship.id])
    end

    it 'can return only seasons that have at least one match' do
      get '/api/v1/seasons', params: { with_matches: true }

      expect(body.map { |s| s['id'] }).to eq([season_2025.id])
    end
  end

  describe 'empty state' do
    it 'returns an empty array when no seasons exist' do
      Season.delete_all

      get '/api/v1/seasons'

      expect(response).to have_http_status(:ok)
      expect(body).to eq([])
    end
  end

  describe 'retrieving a season\'s completed matches without truncation' do
    it 'lets a client page a season completely' do
      # The training flow iterates seasons precisely because the global match
      # list is capped. This proves one season can be fetched in full.
      3.times { |i| add_match(season: season_2025, kickoff: Time.utc(2025, 9, 1 + i, 15, 0)) }

      get '/api/v1/matches', params: { season_id: season_2025.id, status: 'completed', limit: 2000 }

      expect(JSON.parse(response.body).length).to eq(3)
    end
  end
end
