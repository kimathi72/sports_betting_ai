require 'rails_helper'

# Phase 4's safety guarantees, proved against the database rather than inferred
# from the returned result object.
#
#   idempotency      importing the same file twice creates nothing new
#   conflict         a stored completed result is never overwritten
#   promotion        a scheduled fixture becomes completed exactly once
#   rollback         a failed batch leaves no canonical row or mapping behind
#   concurrency      a unique-index race resolves to the winning record
#
# Every count assertion queries PostgreSQL through ActiveRecord, so a result
# object that lies cannot make these pass.
RSpec.describe Import::MatchImporter, 'data-safety guarantees' do
  let(:fixture_path) do
    Rails.root.join('..', 'data', 'fixtures', 'football_data_premier_league_sample.csv').to_s
  end

  let(:mixed_path) do
    Rails.root.join('..', 'data', 'fixtures',
                    'football_data_premier_league_sample_mixed_statuses.csv').to_s
  end

  let(:season_label) { '2024/25' }

  def import(path = fixture_path, season: season_label)
    Import::MatchImporter.new(path: path, season_label: season).call
  end

  # Snapshot of every table the import can write.
  def snapshot
    {
      competitions: Competition.order(:id).pluck(:id, :name),
      seasons: Season.order(:id).pluck(:id, :competition_id, :name),
      teams: Team.order(:id).pluck(:id, :name, :normalized_name),
      matches: Match.order(:id).pluck(:id, :status, :home_score, :away_score),
      identifiers: ExternalIdentifier.order(:id).pluck(:provider, :external_id,
                                                       :competition_id, :season_id,
                                                       :team_id, :match_id),
    }
  end

  # A single-row CSV, so one specific fixture can be exercised in isolation.
  def write_csv(rows)
    path = Tempfile.create(['fixture', '.csv']).path
    File.write(path, "Div,Date,Time,HomeTeam,AwayTeam,FTHG,FTAG,FTR\n" + rows.join("\n") + "\n")
    path
  end

  describe 'idempotency' do
    it 'creates nothing on a second identical import' do
      first = import
      after_first = snapshot

      second = import

      expect(first).to be_success
      expect(second).to be_success
      expect(snapshot).to eq(after_first)
    end

    it 'reports the second run as skipped rather than created' do
      import
      result = import

      expect(result.created).to eq(0)
      expect(result.updated).to eq(0)
      expect(result.skipped).to eq(7)
      expect(result.rejected).to eq(0)
    end

    it 'keeps every table count stable across three runs' do
      3.times { expect(import).to be_success }

      expect(Competition.count).to eq(1)
      expect(Season.count).to eq(1)
      expect(Team.count).to eq(14)
      expect(Match.count).to eq(7)
      # One competition, one season, fourteen teams, seven matches.
      expect(ExternalIdentifier.where.not(competition_id: nil).count).to eq(1)
      expect(ExternalIdentifier.where.not(season_id: nil).count).to eq(1)
      expect(ExternalIdentifier.where.not(team_id: nil).count).to eq(14)
      expect(ExternalIdentifier.where.not(match_id: nil).count).to eq(7)
    end

    it 'does not duplicate matches when the file is re-imported under the same season' do
      import
      keys_before = ExternalIdentifier.where.not(match_id: nil).pluck(:external_id).sort

      import

      expect(ExternalIdentifier.where.not(match_id: nil).pluck(:external_id).sort)
        .to eq(keys_before)
    end
  end

  describe 'completed-result protection' do
    let!(:seeded) do
      # Import the fixture once, then present a contradictory file for one match.
      import
      Match.find_by!(home_team: Team.find_by!(normalized_name: 'manchester united'))
    end

    it 'rejects a batch whose score disagrees with a stored completed result' do
      conflicting = write_csv(['E0,16/08/2024,12:30,Manchester United,Fulham,4,4,D'])

      result = import(conflicting)

      expect(result).to be_failure
      expect(result.rejected).to eq(1)
      expect(result.errors.first[:message]).to match(/conflict|completed/i)
    end

    it 'leaves the stored score and status untouched' do
      conflicting = write_csv(['E0,16/08/2024,12:30,Manchester United,Fulham,4,4,D'])

      import(conflicting)

      seeded.reload
      expect(seeded.home_score).to eq(1)
      expect(seeded.away_score).to eq(0)
      expect(seeded.status).to eq('completed')
    end

    it 'does not change any other stored result either' do
      before = Match.order(:id).pluck(:id, :status, :home_score, :away_score)
      conflicting = write_csv(['E0,16/08/2024,12:30,Manchester United,Fulham,4,4,D'])

      import(conflicting)

      expect(Match.order(:id).pluck(:id, :status, :home_score, :away_score)).to eq(before)
    end

    it 'treats an identical completed result as skipped, not updated' do
      result = import

      expect(result.updated).to eq(0)
      expect(result.skipped).to eq(7)
    end

    it 'refuses to downgrade a completed match back to scheduled' do
      downgrade = write_csv(['E0,16/08/2024,12:30,Manchester United,Fulham,,,'])

      result = import(downgrade)

      expect(result).to be_failure
      seeded.reload
      expect(seeded.status).to eq('completed')
      expect(seeded.home_score).to eq(1)
    end
  end

  describe 'scheduled-to-completed promotion' do
    let(:scheduled_only) do
      write_csv(['E0,24/08/2024,15:00,Brentford,Crystal Palace,,,'])
    end

    let(:with_result) do
      write_csv(['E0,24/08/2024,15:00,Brentford,Crystal Palace,2,1,H'])
    end

    it 'upgrades the existing fixture instead of creating a second match' do
      expect(import(scheduled_only)).to be_success
      expect(Match.count).to eq(1)

      result = import(with_result)

      expect(result).to be_success
      expect(Match.count).to eq(1)
      expect(Match.first.status).to eq('completed')
      expect(Match.first.home_score).to eq(2)
      expect(Match.first.away_score).to eq(1)
    end

    it 'counts the promotion as updated, not created' do
      import(scheduled_only)
      result = import(with_result)

      expect(result.created).to eq(0)
      expect(result.updated).to eq(1)
      expect(result.skipped).to eq(0)
    end

    it 'counts a repeat of the promoted result as skipped' do
      import(scheduled_only)
      import(with_result)
      result = import(with_result)

      expect(result.updated).to eq(0)
      expect(result.skipped).to eq(1)
      expect(Match.count).to eq(1)
    end

    it 'keeps the original kickoff when promoting' do
      import(scheduled_only)
      original_kickoff = Match.first.kickoff_at
      import(with_result)

      expect(Match.first.kickoff_at).to eq(original_kickoff)
    end
  end

  describe 'atomic rollback' do
    # Three rows: two fully valid (which create a competition, a season, five
    # teams, two matches and their identifiers) then one invalid.
    let(:path) do
      write_csv([
                  'E0,16/08/2024,12:30,Manchester United,Fulham,1,0,H',
                  'E0,17/08/2024,15:00,Arsenal,Wolverhampton Wanderers,2,0,H',
                  'E0,18/08/2024,15:00,Everton,,0,3,A',
                ])
    end

    it 'leaves no canonical row behind' do
      import(path)

      expect(Competition.count).to eq(0)
      expect(Season.count).to eq(0)
      expect(Team.count).to eq(0)
      expect(Match.count).to eq(0)
    end

    it 'leaves no external identifier behind' do
      import(path)

      expect(ExternalIdentifier.count).to eq(0)
    end

    it 'leaves the whole database exactly as it was' do
      before = snapshot
      import(path)

      expect(snapshot).to eq(before)
    end

    it 'preserves pre-existing canonical records untouched' do
      competition = Competition.create!(name: 'Preserved League')
      team = Team.create!(name: 'Preserved FC')
      before_team = team.reload.attributes

      import(path)

      expect(Competition.exists?(competition.id)).to be(true)
      expect(Team.find(team.id).attributes).to eq(before_team)
    end

    it 'rolls back rows written earlier in the same batch, not just the bad one' do
      # The first valid row alone would persist 3 teams and 1 match.
      result = import(path)

      expect(result).to be_failure
      expect(Team.find_by(normalized_name: 'manchester united')).to be_nil
      expect(Match.count).to eq(0)
    end

    it 'reports the failure without claiming any writes' do
      result = import(path)

      expect(result).to be_failure
      expect([result.created, result.updated, result.skipped]).to eq([0, 0, 0])
      expect(result.rejected).to eq(3)
    end

    it 'can still import successfully after a rolled-back attempt' do
      import(path)

      expect(import(mixed_path)).to be_success
      expect(Match.count).to eq(7)
    end
  end

  describe 'concurrency' do
    it 'resolves a unique race to one match, not two' do
      row = {
        'Div' => 'E0', 'Date' => '16/08/2024', 'Time' => '12:30',
        'HomeTeam' => 'Manchester United', 'AwayTeam' => 'Fulham',
        'FTHG' => '1', 'FTAG' => '0', 'FTR' => 'H'
      }
      parsed = Import::FootballDataCoUkAdapter.parse(row).row
      resolver = Import::ReferenceResolver.new(provider: 'football_data')

      # First writer wins normally.
      first = resolver.resolve_row(parsed, season_label: season_label)
      expect(first).to be_success

      # Second writer's mapping lookup misses (as a read-committed race would),
      # then hits the unique index on insert. The resolver must recover.
      original = Import::ReferenceResolver.instance_method(:find_identifier)
      calls = 0
      allow_any_instance_of(Import::ReferenceResolver).to receive(:find_identifier) do |res, kind, id|
        calls += 1
        calls == 1 ? nil : original.bind_call(res, kind, id)
      end

      second = resolver.resolve_row(parsed, season_label: season_label)

      expect(second).to be_success
      expect(second.match.id).to eq(first.match.id)
      expect(Match.count).to eq(1)
    end

    it 'does not create duplicate identifiers when the same row resolves twice' do
      row = {
        'Div' => 'E0', 'Date' => '16/08/2024', 'Time' => '12:30',
        'HomeTeam' => 'Manchester United', 'AwayTeam' => 'Fulham',
        'FTHG' => '1', 'FTAG' => '0', 'FTR' => 'H'
      }
      parsed = Import::FootballDataCoUkAdapter.parse(row).row
      resolver = Import::ReferenceResolver.new(provider: 'football_data')

      2.times { resolver.resolve_row(parsed, season_label: season_label) }

      expect(ExternalIdentifier.where.not(competition_id: nil).count).to eq(1)
      expect(ExternalIdentifier.where.not(season_id: nil).count).to eq(1)
      expect(ExternalIdentifier.where.not(team_id: nil).count).to eq(2)
      expect(ExternalIdentifier.where.not(match_id: nil).count).to eq(1)
    end
  end
end
