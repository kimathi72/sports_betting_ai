require 'rails_helper'
require 'rake'

# The download task is operator-facing, so its argument handling matters as much
# as the downloader's: a missing season must fail loudly, and a per-season failure
# must produce a non-zero exit status rather than a cheerful summary.
RSpec.describe 'rake import:download' do
  before(:all) { Rails.application.load_tasks if Rake::Task.tasks.empty? }

  let(:task) { Rake::Task['import:download'] }
  let(:downloader) { instance_double(Import::CsvDownloader) }

  before do
    task.reenable
    allow(Import::CsvDownloader).to receive(:new).and_return(downloader)
  end

  def run_task(seasons)
    task.reenable
    original_stdout = $stdout
    original_stderr = $stderr
    $stdout = StringIO.new
    $stderr = StringIO.new

    begin
      # Array arguments exercise the same path as `rake "task[a,b,c]"`, where
      # Rake puts the first token in the named arg and the rest in args.extras.
      seasons.is_a?(Array) ? task.invoke(*seasons) : task.invoke(seasons)
      :success
    rescue SystemExit => e
      e.status
    ensure
      @out = $stdout.string
      @err = $stderr.string
      $stdout = original_stdout
      $stderr = original_stderr
    end
  end

  def ok_result(season:, already: false)
    Import::CsvDownloader::Result.new(
      season: season, season_code: season.delete('/'), division: 'E0',
      file_path: "/data/raw/#{season.delete('/')}_E0.csv", metadata_path: '/tmp/meta.json',
      status: already ? :already_present : :downloaded,
      checksum: 'a' * 64, size: 1234, has_time_column: true
    )
  end

  describe 'argument validation' do
    it 'rejects an unsupported DIVISION with one clean line and a non-zero status' do
      # Construction validates the division; doing it outside the rescue leaked a
      # Rake backtrace to the operator.
      allow(Import::CsvDownloader).to receive(:new).and_call_original
      original = ENV.fetch('DIVISION', nil)
      # SP1 (La Liga) became a supported division in the competition expansion, so
      # this example needs a code the source does not have at all.
      ENV['DIVISION'] = 'ZZ9'

      begin
        status = run_task('2024/25')
      ensure
        original.nil? ? ENV.delete('DIVISION') : ENV['DIVISION'] = original
      end

      expect(status).to eq(1)
      expect(@err).to match(/invalid input/i)
      expect(@err).not_to match(/from .*\.rb:\d+/)
    end

    it 'fails without a season argument' do
      status = run_task(nil)

      expect(status).to eq(1)
      expect(@err).to match(/usage/i)
      expect(downloader).not_to have_received(:download_one) if downloader.respond_to?(:download_one)
    end

    it 'does not download anything by default' do
      run_task('')

      # No "everything" default: the archive must never be fetched accidentally.
      expect(Import::CsvDownloader).not_to have_received(:new)
    end
  end

  describe 'successful downloads' do
    it 'downloads each requested season' do
      allow(downloader).to receive(:download_one) { |season:| ok_result(season: season) }

      status = run_task('2024/25,2025/26')

      expect(status).to eq(:success)
      expect(downloader).to have_received(:download_one).with(season: '2024/25')
      expect(downloader).to have_received(:download_one).with(season: '2025/26')
      expect(@out).to include('downloaded: 2024/25')
    end

    it 'reports an already-present file without treating it as an error' do
      allow(downloader).to receive(:download_one) { |season:| ok_result(season: season, already: true) }

      status = run_task('2024/25')

      expect(status).to eq(:success)
      expect(@out).to include('already present')
    end

    it 'accepts seasons separated by whitespace as well as commas' do
      allow(downloader).to receive(:download_one) { |season:| ok_result(season: season) }

      run_task('2024/25 2025/26')

      expect(downloader).to have_received(:download_one).twice
    end

    it 'downloads every season when Rake splits the bracket argument on commas' do
      # Rake splits `import:download[a,b,c]` into extra args, so the declared
      # `seasons` arg receives only "a". The task must take the rest from
      # args.extras, otherwise a multi-season request silently downloads one.
      allow(downloader).to receive(:download_one) { |season:| ok_result(season: season) }

      status = run_task(%w[2024/25 2025/26 2023/24])

      expect(status).to eq(:success)
      expect(downloader).to have_received(:download_one).with(season: '2024/25')
      expect(downloader).to have_received(:download_one).with(season: '2025/26')
      expect(downloader).to have_received(:download_one).with(season: '2023/24')
      expect(@out).to include('3 season(s) ready')
    end
  end

  describe 'failure handling' do
    it 'exits non-zero when a season is unavailable' do
      allow(downloader).to receive(:download_one)
        .and_raise(Import::CsvDownloader::Unavailable, 'season 2026/27 is not available (HTTP 404)')

      status = run_task('2026/27')

      expect(status).to eq(1)
      expect(@err).to match(/unavailable/i)
      expect(@err).to match(/1 of 1/)
    end

    it 'continues to later seasons after one fails, then exits non-zero' do
      allow(downloader).to receive(:download_one) do |season:|
        raise Import::CsvDownloader::Unavailable, 'not available' if season == '2026/27'

        ok_result(season: season)
      end

      status = run_task('2026/27,2024/25')

      expect(status).to eq(1)
      expect(downloader).to have_received(:download_one).twice
      expect(@out).to include('downloaded: 2024/25')
      expect(@err).to match(/1 of 2/)
    end

    it 'reports invalid input without a stack trace' do
      allow(downloader).to receive(:download_one)
        .and_raise(Import::CsvDownloader::InvalidInput, 'unknown season "2099/30"')

      status = run_task('2099/30')

      expect(status).to eq(1)
      expect(@err).to match(/invalid input/i)
      expect(@err).not_to match(/\.rb:\d+|backtrace/i)
    end
  end
end
