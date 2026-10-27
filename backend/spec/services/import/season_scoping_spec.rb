require 'rails_helper'

# A match identity must be scoped to its season.
#
# The provider publishes no match id, so identity is derived from the fixture
# (division, date, time, teams). That is enough to tell two fixtures apart, but
# NOT enough to tell the same fixture in two different seasons apart: a file
# imported under 2025/26 would otherwise resolve to the 2024/25 match, silently
# attaching new-season data to an old season — or, worse, reporting a fresh file
# as "already imported" and creating nothing.
RSpec.describe Import::MatchImporter, 'season scoping' do
  let(:fixture_path) do
    Rails.root.join('..', 'data', 'fixtures', 'football_data_premier_league_sample.csv').to_s
  end

  def import(season:)
    Import::MatchImporter.new(path: fixture_path, season_label: season).call
  end

  it 'keeps the same fixture in different seasons as separate matches' do
    expect(import(season: '2024/25')).to be_success
    expect(import(season: '2025/26')).to be_success

    expect(Match.count).to eq(14)
    expect(Match.where(season: Season.find_by!(name: '2024/25')).count).to eq(7)
    expect(Match.where(season: Season.find_by!(name: '2025/26')).count).to eq(7)
  end

  it 'does not count a new season as already imported' do
    import(season: '2024/25')
    result = import(season: '2025/26')

    expect(result.created).to eq(7)
    expect(result.skipped).to eq(0)
  end

  it 'still skips a genuine repeat within one season' do
    import(season: '2024/25')
    result = import(season: '2024/25')

    expect(result.created).to eq(0)
    expect(result.skipped).to eq(7)
    expect(Match.count).to eq(7)
  end

  it 'scopes the provider match identifier by season' do
    import(season: '2024/25')
    import(season: '2025/26')

    ids_2024 = Match.where(season: Season.find_by!(name: '2024/25')).pluck(:id)
    ids_2025 = Match.where(season: Season.find_by!(name: '2025/26')).pluck(:id)

    external = ExternalIdentifier.where.not(match_id: nil)
    expect(external.where(match_id: ids_2024).count).to eq(7)
    expect(external.where(match_id: ids_2025).count).to eq(7)
    expect((ids_2024 & ids_2025)).to be_empty
  end

  it 'never moves an existing match to another season' do
    import(season: '2024/25')
    original = Match.find_by!(home_team: Team.find_by!(normalized_name: 'manchester united'))
    original_season_id = original.season_id

    import(season: '2025/26')

    expect(original.reload.season_id).to eq(original_season_id)
    expect(original.season.name).to eq('2024/25')
  end
end
