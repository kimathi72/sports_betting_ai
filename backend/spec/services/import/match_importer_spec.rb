require 'rails_helper'

# MatchImporter is the persistence layer: it takes a CSV path plus the operator's
# season label, parses it through the reader and adapter, resolves canonical
# records through ReferenceResolver, and writes the batch in ONE transaction.
#
# What these specs insist on:
#   - persisted state is queried from the database, not inferred from the result
#   - a rejected batch leaves NOTHING behind, including the reference records and
#     external identifiers it created before the bad row
#   - provider column names never appear in this class's interface
#
# The specs use the committed synthetic fixtures; no network access is involved.
RSpec.describe Import::MatchImporter do
  let(:fixture_path) do
    Rails.root.join('..', 'data', 'fixtures',
                    'football_data_premier_league_sample.csv').to_s
  end

  let(:season_label) { '2024/25' }

  def importer(path = fixture_path, season: season_label)
    described_class.new(path: path, season_label: season)
  end

  def counts
    {
      competitions: Competition.count,
      seasons: Season.count,
      teams: Team.count,
      matches: Match.count,
      identifiers: ExternalIdentifier.count,
    }
  end

  describe '#call on a valid file' do
    it 'reports success with accurate counters' do
      result = importer.call

      expect(result).to be_success
      expect(result.input).to eq(7)
      expect(result.created).to eq(7)
      expect(result.updated).to eq(0)
      expect(result.skipped).to eq(0)
      expect(result.rejected).to eq(0)
      expect(result.errors).to eq([])
    end

    it 'persists one competition, one season and the teams it saw' do
      importer.call

      expect(Competition.count).to eq(1)
      expect(Season.count).to eq(1)
      # Manchester United, Fulham, Arsenal, Wolves, Everton, Brighton, Newcastle,
      # Southampton, Nottingham Forest, Bournemouth, West Ham, Aston Villa,
      # Brentford, Crystal Palace.
      expect(Team.count).to eq(14)
    end

    it 'persists every match with its result and associations' do
      importer.call

      match = Match.find_by!(home_team: Team.find_by!(normalized_name: 'manchester united'))

      expect(match.status).to eq('completed')
      expect(match.home_score).to eq(1)
      expect(match.away_score).to eq(0)
      # The stored name is the competition, not the import code (see
      # CompetitionCatalogue): "football_data competition E0" is unreadable in the
      # API and in the mobile app.
      expect(match.competition.name).to eq('Premier League')
      expect(match.season.name).to eq('2024/25')
      expect(match.kickoff_at).to eq(Time.utc(2024, 8, 16, 12, 30))
    end

    it 'records a provider identifier for the competition, season and every match' do
      importer.call

      expect(
        ExternalIdentifier.where(provider: 'football_data').where.not(competition_id: nil).count
      ).to eq(1)
      expect(
        ExternalIdentifier.where(provider: 'football_data').where.not(season_id: nil).count
      ).to eq(1)
      expect(
        ExternalIdentifier.where(provider: 'football_data').where.not(match_id: nil).count
      ).to eq(7)
    end

    it 'stores match identifiers keyed by season and the natural fixture key' do
      importer.call

      keys = ExternalIdentifier.where(provider: 'football_data').where.not(match_id: nil)
                               .pluck(:external_id)

      # Scoped by competition and season so the same fixture in another season is
      # a different match. See season_scoping_spec.rb.
      competition = Competition.first
      season = Season.first
      expect(keys).to include(
        "#{competition.id}:#{season.id}:E0|2024-08-16|12:30|manchester united|fulham"
      )
      expect(keys.uniq.length).to eq(7)
    end

    it 'does not expose provider column names in its interface' do
      # The importer knows paths and season labels, not Div/HomeTeam/FTHG.
      expect(described_class.instance_method(:initialize).parameters.map(&:last))
        .to contain_exactly(:path, :season_label)
    end
  end

  describe '#call on the mixed-status fixture' do
    let(:mixed_path) do
      Rails.root.join('..', 'data', 'fixtures',
                      'football_data_premier_league_sample_mixed_statuses.csv').to_s
    end

    it 'persists completed, postponed and scheduled matches with the right status' do
      result = importer(mixed_path).call

      expect(result).to be_success
      expect(result.created).to eq(7)

      expect(Match.where(status: 'completed').count).to eq(4)
      expect(Match.where(status: 'postponed').count).to eq(1)
      expect(Match.where(status: 'scheduled').count).to eq(2)
    end

    it 'leaves non-completed matches without scores' do
      importer(mixed_path).call

      expect(Match.where.not(status: 'completed').pluck(:home_score, :away_score))
        .to all(eq([nil, nil]))
    end
  end

  describe 'input validation' do
    it 'rejects a missing file without touching the database' do
      expect { importer('/nonexistent/file.csv').call }.not_to change { counts }
    end

    it 'reports the missing file as a failure' do
      result = importer('/nonexistent/file.csv').call

      expect(result).to be_failure
      expect(result.errors.first[:message]).to match(/no such file|not found|empty/i)
    end

    it 'rejects a missing season label' do
      result = importer(fixture_path, season: '').call

      expect(result).to be_failure
      expect(result.errors.first[:message]).to match(/season/i)
      expect(Match.count).to eq(0)
    end

    it 'rejects an invalid season label' do
      result = importer(fixture_path, season: 'twenty four').call

      expect(result).to be_failure
      expect(result.errors.first[:message]).to match(/season/i)
    end

    it 'rejects a file whose header omits required columns' do
      Tempfile.create(['bad_headers', '.csv']) do |file|
        file.write("Div,HomeTeam\n")
        file.write("E0,Arsenal\n")
        file.flush

        result = importer(file.path).call

        expect(result).to be_failure
        expect(result.errors.first[:message]).to match(/column/i)
        expect(Match.count).to eq(0)
      end
    end

    it 'rejects malformed CSV' do
      Tempfile.create(['malformed', '.csv']) do |file|
        file.write("Div,Date,Time,HomeTeam,AwayTeam,FTHG,FTAG,FTR\n")
        file.write("E0,16/08/2024,12:30,\"unterminated,1,0,H\n")
        file.flush

        result = importer(file.path).call

        expect(result).to be_failure
        expect(result.errors.first[:message]).to match(/malformed/i)
      end
    end

    it 'rejects an empty file' do
      Tempfile.create(['empty', '.csv']) do |file|
        file.flush

        result = importer(file.path).call

        expect(result).to be_failure
        expect(result.errors.first[:message]).to match(/empty/i)
      end
    end
  end

  describe 'row-level rejection and whole-batch atomicity' do
    # A file whose first two rows are valid and whose last row is not. The
    # importer must have created references and matches for the valid rows before
    # it reaches the bad one; all of that must be rolled back.
    around do |example|
      Tempfile.create(['partially_bad', '.csv']) do |file|
        file.write("Div,Date,Time,HomeTeam,AwayTeam,FTHG,FTAG,FTR\n")
        file.write("E0,16/08/2024,12:30,Manchester United,Fulham,1,0,H\n")
        file.write("E0,17/08/2024,15:00,Arsenal,Wolverhampton Wanderers,2,0,H\n")
        file.write("E0,18/08/2024,15:00,Everton,,0,3,A\n")
        file.flush
        @partially_bad_path = file.path
        example.run
      end
    end

    let(:partially_bad_path) { @partially_bad_path }

    it 'reports failure with one actionable error per bad row' do
      result = importer(partially_bad_path).call

      expect(result).to be_failure
      expect(result.errors.length).to eq(1)
      expect(result.errors.first[:message]).to match(/away team/i)
    end

    it 'counts every row in the batch as rejected, because none was persisted' do
      result = importer(partially_bad_path).call

      expect(result.input).to eq(3)
      expect(result.rejected).to eq(3)
    end

    it 'numbers the failing row one-based' do
      result = importer(partially_bad_path).call

      expect(result.errors.first[:row]).to eq(3)
    end

    it 'leaves no competition, season, team, match or identifier behind' do
      before = counts
      importer(partially_bad_path).call

      expect(counts).to eq(before)
    end

    it 'claims nothing was written in its counters' do
      result = importer(partially_bad_path).call

      expect(result.created).to eq(0)
      expect(result.updated).to eq(0)
      expect(result.skipped).to eq(0)
    end

    it 'preserves records that existed before the failed batch' do
      existing = Team.create!(name: 'Chelsea')
      importer(partially_bad_path).call

      expect(Team.exists?(existing.id)).to be(true)
      expect(Team.count).to eq(1)
    end

    it 'reports nothing about earlier rows as committed' do
      # 2 valid rows were parsed and would have written 3 teams; none may exist.
      importer(partially_bad_path).call

      expect(Team.find_by(normalized_name: 'manchester united')).to be_nil
      expect(ExternalIdentifier.where(provider: 'football_data')).to be_empty
    end
  end

  describe 'error safety' do
    it 'never leaks SQL or driver messages' do
      result = importer('/nonexistent/file.csv').call

      result.errors.each do |error|
        expect(Import::Result.format_error(error)).not_to match(/PG::|ActiveRecord::|SQL|stack/i)
      end
    end

    it 'translates a database failure during persistence into a safe row error' do
      allow(ExternalIdentifier).to receive(:create!).and_raise(
        ActiveRecord::StatementInvalid.new('PG::UndefinedColumn: boom')
      )

      result = importer.call

      expect(result).to be_failure
      expect(result.errors.first[:message]).not_to match(/PG::|UndefinedColumn/)
      expect(Match.count).to eq(0)
    end
  end

  describe 'the returned object' do
    it 'returns an Import::Result' do
      expect(importer.call).to be_a(Import::Result)
    end
  end
end
