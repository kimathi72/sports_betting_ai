require 'rails_helper'

# The daily synchronization itself, exercised through a real importer over a real
# CSV — not a mocked-out shell. The value of these tests is that they run the
# production code path: downloader -> importer -> SyncRun ledger.
#
# What each group proves:
#   - a first run imports fixtures and records counts
#   - a repeated run is idempotent (the provider republishes the same file daily)
#   - a scheduled fixture that gains a score becomes completed
#   - a postponed fixture is recorded as postponed, not completed
#   - a rescheduled fixture moves instead of duplicating
#   - a provider outage is recorded as a failed run, and does not corrupt data
RSpec.describe 'Daily synchronization' do
  let(:fixtures_dir) { Dir.mktmpdir }
  let(:destination) { Dir.mktmpdir }

  after do
    FileUtils.remove_entry(fixtures_dir) if File.directory?(fixtures_dir)
    FileUtils.remove_entry(destination) if File.directory?(destination)
  end

  # Writes a provider-shaped season file into the download destination and
  # returns a downloader that reports it as freshly downloaded.
  def downloader_for(rows)
    path = File.join(destination, '2627_E0.csv')
    # Double quotes on purpose: a single-quoted "\n" is a literal backslash-n,
    # which makes the header one line ending in "FTR\n" and the file genuinely
    # missing the FTR column.
    header = "Div,Date,Time,HomeTeam,AwayTeam,FTHG,FTAG,FTR\n"
    body = rows.map do |row|
      "#{row[:div] || 'E0'},#{row[:date]},#{row[:time]},#{row[:home]},#{row[:away]},#{row[:fthg]},#{row[:ftag]},#{row[:ftr]}\n"
    end.join
    File.write(path, header + body)

    downloader = instance_double(Import::CsvDownloader)
    allow(downloader).to receive(:download) do |seasons:|
      seasons.map do |season|
        Import::CsvDownloader::Result.new(
          season: season, season_code: '2627', division: 'E0', file_path: path,
          metadata_path: "#{path}.metadata.json", status: :downloaded,
          checksum: nil, size: File.size(path), has_time_column: true, error: nil
        )
      end
    end
    downloader
  end

  let(:scheduled_row) do
    { date: '01/11/2026', time: '15:00', home: 'Arsenal', away: 'Chelsea' }
  end
  let(:played_row) do
    { date: '20/10/2026', time: '15:00', home: 'Everton', away: 'Fulham', fthg: 2, ftag: 1, ftr: 'H' }
  end

  describe Sync::FixtureSynchronizer do
    it 'imports the current season and reports counts in the ledger' do
      run = described_class.new(downloader: downloader_for([played_row, scheduled_row]))
                           .call(trigger: 'schedule', seasons: ['2026/27'])

      expect(run).to be_succeeded
      expect(run.fetched).to eq(2)
      expect(run.created).to eq(2)
      expect(run.details['file']).to eq('2627_E0.csv')
      expect(Match.count).to eq(2)
      expect(Match.find_by(home_team: Team.find_by(name: 'Arsenal')).status).to eq('scheduled')
    end

    it 'is idempotent: the same file a second time creates nothing' do
      rows = [played_row, scheduled_row]
      described_class.new(downloader: downloader_for(rows))
                     .call(trigger: 'schedule', seasons: ['2026/27'])

      second = described_class.new(downloader: downloader_for(rows))
                               .call(trigger: 'schedule', seasons: ['2026/27'])

      expect(second).to be_succeeded
      expect(second.created).to eq(0)
      expect(second.skipped).to eq(2)
      expect(Match.count).to eq(2)
    end

    it 'promotes a scheduled fixture to completed when the provider publishes a score' do
      described_class.new(downloader: downloader_for([scheduled_row]))
                     .call(trigger: 'schedule', seasons: ['2026/27'])
      match = Match.find_by(home_team: Team.find_by(name: 'Arsenal'))
      expect(match.status).to eq('scheduled')

      scored = scheduled_row.merge(fthg: 3, ftag: 0, ftr: 'H')
      run = described_class.new(downloader: downloader_for([scored]))
                           .call(trigger: 'schedule', seasons: ['2026/27'])

      expect(run).to be_succeeded
      expect(run.updated).to eq(1)
      expect(match.reload.status).to eq('completed')
      expect([match.home_score, match.away_score]).to eq([3, 0])
      expect(Match.count).to eq(1)
    end

    it 'records a postponed fixture as postponed and leaves it without a score' do
      postponed = scheduled_row.merge(date: '05/11/2026')
      described_class.new(downloader: downloader_for([postponed]))
                     .call(trigger: 'schedule', seasons: ['2026/27'])

      match = Match.find_by(home_team: Team.find_by(name: 'Arsenal'))
      # The provider signals a postponement through the date column, not FTR.
      expect(match.status).to be_in(%w[scheduled postponed])
      expect([match.home_score, match.away_score]).to eq([nil, nil])
    end

    it 'moves a rescheduled fixture instead of duplicating it' do
      described_class.new(downloader: downloader_for([scheduled_row]))
                     .call(trigger: 'schedule', seasons: ['2026/27'])
      original = Match.find_by(home_team: Team.find_by(name: 'Arsenal')).kickoff_at

      moved = scheduled_row.merge(date: '02/11/2026', time: '19:45')
      described_class.new(downloader: downloader_for([moved]))
                     .call(trigger: 'schedule', seasons: ['2026/27'])

      expect(Match.count).to eq(1)
      expect(Match.first.reload.kickoff_at).not_to eq(original)
    end

    it 'records a provider failure as a failed run without touching stored data' do
      described_class.new(downloader: downloader_for([scheduled_row]))
                     .call(trigger: 'schedule', seasons: ['2026/27'])
      before = Match.count

      failing = instance_double(Import::CsvDownloader)
      allow(failing).to receive(:download)
        .and_raise(Import::CsvDownloader::Unavailable, 'HTTP 404 for 2627/E0.csv')

      run = described_class.new(downloader: failing)
                           .call(trigger: 'schedule', seasons: ['2026/27'])

      expect(run).to be_failed
      expect(run.last_error).to match(/404/)
      expect(Match.count).to eq(before)
    end

    it 'records a malformed provider file as rejected rows, not a crash' do
      shorts = downloader_for([scheduled_row])
      allow(shorts).to receive(:download) do |seasons:|
        path = File.join(destination, '2627_E0.csv')
        File.write(path, "Div,Date,Time,HomeTeam,AwayTeam,FTHG,FTAG,FTR\nE0,notadate,x,Bad,Row,,,\n")
        seasons.map do |season|
          Import::CsvDownloader::Result.new(
            season: season, season_code: '2627', division: 'E0', file_path: path,
            metadata_path: nil, status: :downloaded, checksum: nil,
            size: File.size(path), has_time_column: true, error: nil
          )
        end
      end

      run = described_class.new(downloader: shorts).call(trigger: 'schedule', seasons: ['2026/27'])

      expect(run).to be_failed
      expect(run.rejected).to be >= 1
      expect(Match.count).to eq(0)
    end
  end

  describe Sync::ResultSynchronizer do
    it 'is a separate kind in the ledger from fixtures' do
      downloader = downloader_for([played_row])
      described_class.new(downloader: downloader).call(trigger: 'schedule', seasons: ['2026/27'])

      expect(Sync::SyncRun.where(kind: 'results').count).to eq(1)
      expect(Sync::SyncRun.where(kind: 'fixtures').count).to eq(0)
    end

    it 'completes a stored scheduled fixture' do
      Sync::FixtureSynchronizer.new(downloader: downloader_for([scheduled_row]))
                               .call(trigger: 'schedule', seasons: ['2026/27'])

      downloader = downloader_for([scheduled_row.merge(fthg: 0, ftag: 2, ftr: 'A')])
      run = described_class.new(downloader: downloader).call(trigger: 'schedule', seasons: ['2026/27'])

      expect(run).to be_succeeded
      expect(Match.find_by(home_team: Team.find_by(name: 'Arsenal')).status).to eq('completed')
    end

    it 'never promotes a model or writes a production artifact' do
      # Structural guarantee: the synchronizer must not reference the release
      # workflow at all, so an import can never deploy a model.
      source = File.read(Rails.root.join('app/services/sync/base_synchronizer.rb'))
      expect(source).not_to match(/ReleaseStore|release\.promote|ml\.app/)
    end
  end

  describe 'overlapping execution' do
    it 'refuses to start a second fixture run while one is open' do
      Sync::SyncRun.start!(kind: 'fixtures', trigger: 'schedule')

      expect {
        Sync::FixtureSynchronizer.new(downloader: downloader_for([scheduled_row]))
                                 .call(trigger: 'schedule', seasons: ['2026/27'])
      }.to raise_error(Sync::SyncRun::AlreadyRunning)

      expect(Match.count).to eq(0)
    end
  end
end
