require 'rails_helper'

# Retry behaviour must distinguish "try again" from "this will never work".
#
# Retrying a malformed CSV burns worker capacity and delays the operator seeing the
# real problem, while never retrying a dropped connection loses an import that
# would have succeeded. The classification lives in the job's `rescue_from`
# handlers so it applies to every path, including validation.
RSpec.describe ImportFootballDataJob, 'retry policy' do
  let(:fixture_path) do
    Rails.root.join('..', 'data', 'fixtures', 'football_data_premier_league_sample.csv').to_s
  end

  let(:season_label) { '2024/25' }

  around do |example|
    Dir.mktmpdir('retry_spec') do |dir|
      original = ENV.fetch('IMPORT_ALLOWED_ROOTS', nil)
      ENV['IMPORT_ALLOWED_ROOTS'] = [original, dir].compact.join(File::PATH_SEPARATOR)
      @scratch_dir = dir
      example.run
    ensure
      original.nil? ? ENV.delete('IMPORT_ALLOWED_ROOTS') : ENV['IMPORT_ALLOWED_ROOTS'] = original
    end
  end

  # ActiveJob captures rescue_from handlers per class; the minimal way to observe
  # which policy fired without a live Sidekiq server is to rescue the process the
  # job raises and inspect it.
  def execute(path, season)
    described_class.perform_now(path, season)
  rescue StandardError => e
    e
  end

  describe 'permanent failures are not retried' do
    it 'does not retry a rejected import' do
      path = File.join(@scratch_dir, 'bad.csv')
      File.write(path, "Div,Date,Time,HomeTeam,AwayTeam,FTHG,FTAG,FTR\nE0,17/08/2024,15:00,,X,1,0,H\n")

      error = execute(path, season_label)

      expect(error).to be_a(ImportFootballDataJob::ImportFailed)
      expect(error).not_to be_a(ImportFootballDataJob::TransientFailure)
    end

    it 'does not retry a missing file' do
      error = execute('/nonexistent/nope.csv', season_label)

      expect(error).to be_a(ImportFootballDataJob::ImportFailed)
    end

    it 'does not retry a path outside the import directory' do
      error = execute('/etc/passwd', season_label)

      expect(error).to be_a(ImportFootballDataJob::ImportFailed)
    end

    it 'does not retry an invalid season label' do
      error = execute(fixture_path, 'soon')

      expect(error).to be_a(ImportFootballDataJob::ImportFailed)
    end
  end

  describe 'completed-result conflicts are permanent' do
    it 'does not retry a conflict with a stored result' do
      described_class.new.run(fixture_path, season_label)

      path = File.join(@scratch_dir, 'conflict.csv')
      File.write(path, "Div,Date,Time,HomeTeam,AwayTeam,FTHG,FTAG,FTR\n" \
                       "E0,16/08/2024,12:30,Manchester United,Fulham,5,5,D\n")

      error = execute(path, season_label)

      expect(error).to be_a(ImportFootballDataJob::ImportFailed)
      expect(error.message).to match(/conflict/i)
    end
  end

  describe 'transient failures are retried' do
    it 'wraps a database connection failure as transient' do
      allow(Import::MatchImporter).to receive(:new).and_raise(
        ActiveRecord::ConnectionNotEstablished, 'connection lost'
      )

      error = execute(fixture_path, season_label)

      expect(error).to be_a(ImportFootballDataJob::TransientFailure)
      expect(error.cause).to be_a(ActiveRecord::ConnectionNotEstablished)
    end

    it 'wraps a deadlock as transient' do
      allow(Import::MatchImporter).to receive(:new).and_raise(
        ActiveRecord::Deadlocked, 'deadlock detected'
      )

      expect(execute(fixture_path, season_label)).to be_a(ImportFootballDataJob::TransientFailure)
    end

    it 'treats a lost lock wait as transient' do
      allow(Import::MatchImporter).to receive(:new).and_raise(
        ActiveRecord::LockWaitTimeout, 'lock timeout'
      )

      expect(execute(fixture_path, season_label)).to be_a(ImportFootballDataJob::TransientFailure)
    end
  end

  describe 'unexpected failures' do
    it 'does not swallow a programming error' do
      allow(Import::MatchImporter).to receive(:new).and_raise(NoMethodError, 'undefined method')

      error = execute(fixture_path, season_label)

      expect(error).to be_a(NoMethodError)
      expect(error).not_to be_a(ImportFootballDataJob::ImportFailed)
    end
  end

  describe 'policy configuration' do
    it 'bounds retries for transient failures' do
      expect(described_class::MAX_RETRIES).to be_between(1, 10)
    end

    it 'uses an explicit retry wait' do
      expect(described_class::RETRY_WAIT).to be_a(Integer)
    end

    it 'declares the transient error classes it retries' do
      expect(described_class::TRANSIENT_ERRORS).to include(
        ActiveRecord::ConnectionNotEstablished,
        ActiveRecord::Deadlocked,
        ActiveRecord::LockWaitTimeout
      )
    end

    it 'does not list permanent import failures as transient' do
      expect(described_class::TRANSIENT_ERRORS).not_to include(ImportFootballDataJob::ImportFailed)
    end
  end

  describe 'retry safety' do
    it 'does not duplicate data when a retried import finally succeeds' do
      # A transient failure before any write, then the real run: the retry must
      # produce the same single set of rows as a clean first attempt.
      allow(Import::MatchImporter).to receive(:new).and_raise(
        ActiveRecord::ConnectionNotEstablished, 'connection lost'
      ).once
      allow(Import::MatchImporter).to receive(:new).and_call_original

      execute(fixture_path, season_label)
      described_class.perform_now(fixture_path, season_label)
      described_class.perform_now(fixture_path, season_label)

      expect(Match.count).to eq(7)
    end
  end
end
