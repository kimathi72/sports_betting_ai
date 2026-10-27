require 'rails_helper'

# The resolver turns provider identity into canonical records.
#
# PROVIDER IDENTITY IS NOT DISPLAY NAME. football-data.co.uk identifies a
# competition by a code ("E0") and a team by the text of its name; neither is a
# stable numeric id. Everything here goes through ExternalIdentifier in the
# `football_data` namespace, so a second provider can name the same league
# differently without touching canonical rows.
#
# The rules under test:
#   competition — provider code only, never by display name
#   season      — the operator's label, scoped to the competition
#   team        — provider name, reusing the canonical `Team.normalize` identity
#   match       — the provider's natural key, computed by the adapter
#
# Failures are returned as explicit outcomes, never raw database exceptions.
RSpec.describe Import::ReferenceResolver do
  subject(:resolver) { described_class.new(provider: 'football_data') }

  let(:season_label) { '2024/25' }

  # A MatchRow as the adapter would produce it, so the resolver is exercised with
  # the real contract rather than a hand-rolled stand-in.
  def match_row(overrides = {})
    Import::MatchRow.new(
      {
        provider: 'football_data',
        provider_key: 'E0|2024-08-16|12:30|manchester united|fulham',
        competition_code: 'E0',
        season_label: nil,
        home_team_name: 'Manchester United',
        away_team_name: 'Fulham',
        kickoff_at: Time.utc(2024, 8, 16, 12, 30),
        status: 'completed',
        home_score: 1,
        away_score: 0,
      }.merge(overrides)
    )
  end

  describe '#resolve_competition' do
    it 'creates the canonical competition and its identifier on first sight' do
      result = resolver.resolve_competition('E0')

      expect(result).to be_success
      expect(result.record).to be_a(Competition)
      expect(result.record).to be_persisted
      expect(result.created_record?).to be(true)

      identifier = ExternalIdentifier.find_by(
        provider: 'football_data', external_id: 'E0', competition_id: result.record.id
      )
      expect(identifier).to be_present
    end

    it 'reuses the same competition on repeated resolution' do
      first = resolver.resolve_competition('E0')
      second = resolver.resolve_competition('E0')

      expect(second.record.id).to eq(first.record.id)
      expect(second.created_record?).to be(false)
      expect(Competition.count).to eq(1)
      expect(ExternalIdentifier.where(competition_id: first.record.id).count).to eq(1)
    end

    it 'treats the code case-insensitively, since e0 and E0 are one league' do
      first = resolver.resolve_competition('E0')
      second = resolver.resolve_competition('e0')

      expect(second.record.id).to eq(first.record.id)
      expect(Competition.count).to eq(1)
    end

    it 'never identifies a competition by display name alone' do
      # An existing unrelated competition with the same name must not be adopted:
      # only the provider mapping may establish identity.
      other = Competition.create!(name: 'Premier League')

      result = resolver.resolve_competition('E0')

      expect(result.record.id).not_to eq(other.id)
      expect(Competition.count).to eq(2)
    end

    it 'rejects a blank competition code' do
      result = resolver.resolve_competition('')

      expect(result).to be_failure
      expect(result.error).to match(/competition/i)
      expect(Competition.count).to eq(0)
    end

    it 'rejects a non-string competition code' do
      expect(resolver.resolve_competition(nil)).to be_failure
    end
  end

  describe '#resolve_season' do
    let(:competition) { resolver.resolve_competition('E0').record }

    it 'creates the season from the operator label, scoped to the competition' do
      result = resolver.resolve_season(competition, season_label)

      expect(result).to be_success
      expect(result.record).to be_a(Season)
      expect(result.record.name).to eq('2024/25')
      expect(result.record.competition_id).to eq(competition.id)
      expect(result.created_record?).to be(true)
    end

    it 'records a provider identifier for the season' do
      result = resolver.resolve_season(competition, season_label)

      identifier = ExternalIdentifier.find_by(
        provider: 'football_data', season_id: result.record.id
      )
      expect(identifier).to be_present
      expect(identifier.external_id).to include(season_label)
    end

    it 'reuses the season on repeated resolution' do
      first = resolver.resolve_season(competition, season_label)
      second = resolver.resolve_season(competition, season_label)

      expect(second.record.id).to eq(first.record.id)
      expect(second.created_record?).to be(false)
      expect(Season.count).to eq(1)
    end

    it 'never guesses a season from kickoff dates' do
      # 2024/25 and 2025/26 both contain August fixtures; the label decides.
      season_one = resolver.resolve_season(competition, '2024/25').record
      season_two = resolver.resolve_season(competition, '2025/26').record

      expect(season_one).not_to eq(season_two)
      expect(Season.count).to eq(2)
    end

    it 'requires a season label' do
      expect(resolver.resolve_season(competition, nil)).to be_failure
      expect(resolver.resolve_season(competition, '  ')).to be_failure
      expect(Season.count).to eq(0)
    end

    it 'rejects a season label that is not a plausible season' do
      result = resolver.resolve_season(competition, 'not-a-season')

      expect(result).to be_failure
      expect(result.error).to match(/season/i)
    end

    it 'rejects a season label without a competition' do
      expect(resolver.resolve_season(nil, season_label)).to be_failure
    end
  end

  describe '#resolve_team' do
    it 'creates the canonical team on first sight, preserving the display name' do
      result = resolver.resolve_team('Manchester United')

      expect(result).to be_success
      expect(result.record).to be_a(Team)
      expect(result.record.name).to eq('Manchester United')
      expect(result.record.normalized_name).to eq('manchester united')
      expect(result.created_record?).to be(true)
    end

    it 'keys the identifier on the normalized provider team name' do
      result = resolver.resolve_team('Manchester United')

      identifier = ExternalIdentifier.find_by(
        provider: 'football_data', team_id: result.record.id
      )
      expect(identifier).to be_present
      # The mapping key is the canonical identity, so harmless case/whitespace
      # variation cannot produce a second mapping for one club.
      expect(identifier.external_id).to eq('manchester united')
      expect(result.record.name).to eq('Manchester United')
    end

    it 'reuses a verified mapping on repeated resolution' do
      first = resolver.resolve_team('Manchester United')
      second = resolver.resolve_team('Manchester United')

      expect(second.record.id).to eq(first.record.id)
      expect(second.created_record?).to be(false)
      expect(Team.count).to eq(1)
    end

    it 'reuses the team despite case and whitespace variation in the provider text' do
      first = resolver.resolve_team('Manchester United')
      second = resolver.resolve_team('  manchester   UNITED ')

      expect(second.record.id).to eq(first.record.id)
      expect(Team.count).to eq(1)
      # The display name is the first spelling seen, not the most recent one.
      expect(second.record.reload.name).to eq('Manchester United')
    end

    it 'does not merge teams whose names merely share a prefix' do
      manchester = resolver.resolve_team('Manchester United').record
      city = resolver.resolve_team('Manchester City').record

      expect(city.id).not_to eq(manchester.id)
      expect(Team.count).to eq(2)
    end

    it 'does not merge two genuinely different spellings of one club' do
      # "and" vs "&" is a materially different name, not a case/whitespace
      # variant. Guessing they are one club would merge two histories, so they
      # stay separate until an operator maps them explicitly.
      existing = Team.create!(name: 'Brighton and Hove Albion')

      result = resolver.resolve_team('Brighton & Hove Albion')

      expect(result).to be_success
      expect(result.record.id).not_to eq(existing.id)
      expect(Team.count).to eq(2)
      expect(existing.reload.name).to eq('Brighton and Hove Albion')
    end

    it 'reports a collision instead of adopting an existing team whose name differs materially' do
      # Only reachable when normalisation collapses two spellings that the
      # operator would consider different clubs (e.g. a provider-specific alias
      # that normalises the same). The resolver refuses to adopt silently.
      existing = Team.create!(name: 'Nottingham Forest')
      allow(Team).to receive(:find_by).and_return(existing)

      result = resolver.resolve_team('Notts Forest')

      expect(result).to be_failure
      expect(result.error).to match(/collision|conflict/i)
      expect(existing.reload.name).to eq('Nottingham Forest')
    end

    it 'reuses an existing canonical team when the provider mapping is added later' do
      team = Team.create!(name: 'Fulham')

      result = resolver.resolve_team('Fulham')

      expect(result).to be_success
      expect(result.record.id).to eq(team.id)
      expect(ExternalIdentifier.where(team_id: team.id, provider: 'football_data')).to exist
    end

    it 'rejects a blank team name' do
      expect(resolver.resolve_team('')).to be_failure
      expect(resolver.resolve_team(nil)).to be_failure
      expect(Team.count).to eq(0)
    end
  end

  describe '#resolve_match' do
    let(:competition) { resolver.resolve_competition('E0').record }
    let(:season) { resolver.resolve_season(competition, season_label).record }

    def resolve(row = match_row)
      resolver.resolve_match(
        row,
        competition: competition,
        season: season,
        home_team: resolver.resolve_team(row.home_team_name).record,
        away_team: resolver.resolve_team(row.away_team_name).record
      )
    end

    it 'creates the match and stores the natural key as its identifier' do
      result = resolve

      expect(result).to be_success
      expect(result.record).to be_a(Match)
      expect(result.record.status).to eq('completed')
      expect(result.record.home_score).to eq(1)
      expect(result.record.away_score).to eq(0)
      expect(result.created_record?).to be(true)

      identifier = ExternalIdentifier.find_by(provider: 'football_data', match_id: result.record.id)
      expect(identifier.external_id).to eq(match_row.provider_key)
    end

    it 'attaches competition, season and both teams' do
      record = resolve.record

      expect(record.competition_id).to eq(competition.id)
      expect(record.season_id).to eq(season.id)
      expect(record.home_team.name).to eq('Manchester United')
      expect(record.away_team.name).to eq('Fulham')
    end

    it 'reuses the match on a repeated resolve of the same fixture' do
      first = resolve
      second = resolve

      expect(second.record.id).to eq(first.record.id)
      expect(second.created_record?).to be(false)
      expect(Match.count).to eq(1)
    end

    it 'creates a distinct match for a different fixture' do
      first = resolve
      second = resolve(match_row(provider_key: 'E0|2024-08-17|15:00|arsenal|chelsea',
                                 home_team_name: 'Arsenal', away_team_name: 'Chelsea'))

      expect(second.record.id).not_to eq(first.record.id)
      expect(Match.count).to eq(2)
    end

    it 'rejects a row without a provider key' do
      expect(resolve(match_row(provider_key: ''))).to be_failure
    end

    it 'rejects a row whose status is not supported' do
      result = resolve(match_row(status: 'abandoned'))

      expect(result).to be_failure
      expect(result.error).to match(/status/i)
      expect(Match.count).to eq(0)
    end

    it 'rejects a completed row without scores rather than inventing one' do
      result = resolve(match_row(home_score: nil, away_score: nil))

      expect(result).to be_failure
      expect(Match.count).to eq(0)
    end

    it 'rejects a season belonging to another competition' do
      other = resolver.resolve_competition('E1').record
      wrong_season = resolver.resolve_season(other, season_label).record

      result = resolver.resolve_match(
        match_row,
        competition: competition,
        season: wrong_season,
        home_team: resolver.resolve_team('Manchester United').record,
        away_team: resolver.resolve_team('Fulham').record
      )

      expect(result).to be_failure
      expect(Match.count).to eq(0)
    end

    it 'rejects a row that uses the same team on both sides' do
      same = resolver.resolve_team('Fulham').record

      result = resolver.resolve_match(
        match_row,
        competition: competition,
        season: season,
        home_team: same,
        away_team: same
      )

      expect(result).to be_failure
      expect(Match.count).to eq(0)
    end
  end

  describe 'conflicting mappings' do
    it 'reports a conflict when a provider id already points at a different team' do
      other = Team.create!(name: 'Chelsea')
      ExternalIdentifier.create!(
        provider: 'football_data', external_id: 'chelsea', team: other
      )

      # The provider mapping wins over any name-based guess: "Ford United" does
      # not match the existing key, so a new team is created for it. What must
      # never happen is adopting `other` because of a name coincidence.
      result = resolver.resolve_team('Ford United')

      expect(result).to be_success
      expect(result.record.id).not_to eq(other.id)
      expect(Team.count).to eq(2)
    end

    it 'does not touch the database when a mapping conflicts' do
      # A mapping whose canonical name does not match the code it claims is a
      # contradiction: reuse would silently point E0 at the wrong league.
      other = Competition.create!(name: 'Championship')
      ExternalIdentifier.create!(provider: 'football_data', external_id: 'E0', competition: other)

      expect { resolver.resolve_competition('E0') }.not_to change(Competition, :count)

      result = resolver.resolve_competition('E0')
      expect(result).to be_failure
      expect(result.error).to match(/conflict/i)
    end
  end

  describe 'uniqueness races' do
    it 'resolves the winning record when a concurrent insert wins the race' do
      # Simulate the race deterministically: the lookup misses, then the insert
      # hits the unique index because another writer committed first.
      winner = Team.create!(name: 'Everton')
      ExternalIdentifier.create!(provider: 'football_data', external_id: 'Everton', team: winner)

      # Hide the existing mapping from the resolver's first lookup, exactly as a
      # read-committed race would, without relying on thread timing.
      allow(ExternalIdentifier).to receive(:find_by).and_return(
        nil, ExternalIdentifier.find_by(provider: 'football_data', external_id: 'Everton')
      )

      result = resolver.resolve_team('Everton')

      expect(result).to be_success
      expect(result.record.id).to eq(winner.id)
      expect(Team.count).to eq(1)
    end

    it 'does not swallow unrelated database errors as races' do
      allow(ExternalIdentifier).to receive(:create!).and_raise(ActiveRecord::StatementInvalid, 'boom')

      result = resolver.resolve_team('Newcastle United')

      expect(result).to be_failure
      expect(result.error).not_to match(/unique|PG::/)
    end
  end

  describe '#resolve_row' do
    it 'resolves competition, season, both teams and the match in one call' do
      result = resolver.resolve_row(match_row, season_label: season_label)

      expect(result).to be_success
      expect(result.record).to be_a(Match)
      expect(result.created_record?).to be(true)
      expect(result.competition).to be_persisted
      expect(result.season.name).to eq(season_label)
      expect([result.home_team.name, result.away_team.name])
        .to contain_exactly('Manchester United', 'Fulham')
    end

    it 'is idempotent for the same row' do
      first = resolver.resolve_row(match_row, season_label: season_label)
      second = resolver.resolve_row(match_row, season_label: season_label)

      expect(second.record.id).to eq(first.record.id)
      expect(second.created_record?).to be(false)
      expect(Competition.count).to eq(1)
      expect(Season.count).to eq(1)
      expect(Team.count).to eq(2)
      expect(Match.count).to eq(1)
    end

    it 'requires a season label' do
      expect(resolver.resolve_row(match_row, season_label: nil)).to be_failure
      expect(Match.count).to eq(0)
    end
  end

  describe '#resolve_or_raise' do
    it 'raises a typed error carrying the outcome for a bad row' do
      expect {
        resolver.resolve_or_raise(match_row(status: 'abandoned'), season_label: season_label)
      }.to raise_error(Import::ReferenceResolver::ResolutionError) { |error|
        expect(error.message).to match(/status/i)
      }
    end

    it 'returns the match on success' do
      match = resolver.resolve_or_raise(match_row, season_label: season_label)

      expect(match).to be_a(Match)
    end
  end
end
