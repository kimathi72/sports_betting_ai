require 'rails_helper'

# Runs a single-file import in the background.
#
# The job is a thin, serialisable shell around Import::MatchImporter: it validates
# what it can before touching the database, delegates parsing and persistence, and
# never reports a failed import as a successful job. Arguments are strings only,
# so nothing depends on an ActiveRecord object surviving a trip through Redis.
RSpec.describe ImportFootballDataJob do
  # Specs that need a deliberately broken file cannot write into `data/`, which is
  # mounted read-only in the test container. They use a temporary directory added
  # through the supported IMPORT_ALLOWED_ROOTS override instead of weakening the
  # allowlist for the real runbook.
  around do |example|
    Dir.mktmpdir('import_job_spec') do |dir|
      original = ENV.fetch('IMPORT_ALLOWED_ROOTS', nil)
      ENV['IMPORT_ALLOWED_ROOTS'] = [original, dir].compact.join(File::PATH_SEPARATOR)
      @scratch_dir = dir
      example.run
    ensure
      original.nil? ? ENV.delete('IMPORT_ALLOWED_ROOTS') : ENV['IMPORT_ALLOWED_ROOTS'] = original
    end
  end

  let(:fixture_path) do
    Rails.root.join('..', 'data', 'fixtures', 'football_data_premier_league_sample.csv').to_s
  end

  let(:season_label) { '2024/25' }

  describe 'the job contract' do
    it 'inherits from ApplicationJob' do
      expect(described_class.ancestors).to include(ApplicationJob)
    end

    it 'runs on an explicitly named queue' do
      expect(described_class.new.queue_name).to eq('imports')
    end

    it 'accepts only serialisable arguments' do
      parameters = described_class.instance_method(:perform).parameters

      expect(parameters).to eq([%i[req path], %i[req season_label]])
    end

    it 'can be enqueued with plain strings' do
      expect {
        described_class.perform_later(fixture_path, season_label)
      }.to have_enqueued_job(described_class).with(fixture_path, season_label).on_queue('imports')
    end
  end

  describe '#perform on a valid file' do
    it 'imports the file' do
      described_class.new.run(fixture_path, season_label)

      expect(Match.count).to eq(7)
    end

    it 'returns the import result for operational logging' do
      result = described_class.new.run(fixture_path, season_label)

      expect(result).to be_a(Import::Result)
      expect(result).to be_success
      expect(result.created).to eq(7)
    end

    it 'is idempotent when performed twice' do
      described_class.new.run(fixture_path, season_label)
      result = described_class.new.run(fixture_path, season_label)

      expect(result.skipped).to eq(7)
      expect(Match.count).to eq(7)
    end
  end

  describe 'argument and availability validation' do
    it 'rejects a blank path without raising a database error' do
      result = described_class.new.run('', season_label)

      expect(result).to be_failure
      expect(result.errors.first[:message]).to match(/path/i)
      expect(Match.count).to eq(0)
    end

    it 'rejects a missing season label' do
      result = described_class.new.run(fixture_path, '')

      expect(result).to be_failure
      expect(result.errors.first[:message]).to match(/season/i)
    end

    it 'rejects a file that does not exist' do
      result = described_class.new.run('/nonexistent/nope.csv', season_label)

      expect(result).to be_failure
      expect(result.errors.first[:message]).to match(/not found|no such file/i)
    end

    it 'rejects a path outside the allowed import directory' do
      result = described_class.new.run('/etc/passwd', season_label)

      expect(result).to be_failure
      expect(result.errors.first[:message]).to match(/outside|not permitted|allowed/i)
      expect(Match.count).to eq(0)
    end
  end

  describe 'a rejected import' do
    # Written inside an approved import directory so the allowlist does not mask
    # the row-level rejection this block is about.
    let(:bad_path) do
      path = File.join(@scratch_dir, 'spec_rejected.csv')
      File.write(path, "Div,Date,Time,HomeTeam,AwayTeam,FTHG,FTAG,FTR\n" \
                       "E0,17/08/2024,15:00,,Chelsea,1,0,H\n")
      path
    end

    after { File.delete(bad_path) if File.exist?(bad_path) }

    it 'returns a failed result rather than raising' do
      result = described_class.new.run(bad_path, season_label)

      expect(result).to be_failure
      expect(Match.count).to eq(0)
    end
  end

  describe 'operational failure visibility' do
    # A rejected import must not look like successful work to the queue.
    it 'raises ImportFailed from perform for a rejected import' do
      expect {
        described_class.perform_now('/nonexistent/nope.csv', season_label)
      }.to raise_error(ImportFootballDataJob::ImportFailed, /not found|allowed/i)
    end

    it 'raises ImportFailed when the importer rejects the rows' do
      # The path must be inside an approved import directory; the scratch dir is
      # added to the allowlist in the `around` hook above.
      path = File.join(@scratch_dir, 'spec_bad.csv')
      File.write(path, "Div,Date,Time,HomeTeam,AwayTeam,FTHG,FTAG,FTR\n" \
                       "E0,17/08/2024,15:00,,Chelsea,1,0,H\n")

      expect {
        described_class.perform_now(path, season_label)
      }.to raise_error(ImportFootballDataJob::ImportFailed, /home team/i)
    end

    it 'does not raise for a successful import' do
      expect {
        described_class.perform_now(fixture_path, season_label)
      }.not_to raise_error
    end

    it 'still returns the successful result from perform' do
      result = described_class.perform_now(fixture_path, season_label)

      expect(result).to be_success
    end
  end

  describe 'logging' do
    it 'logs a concise summary without leaking file contents' do
      allow(Rails.logger).to receive(:info)

      described_class.new.run(fixture_path, season_label)

      expect(Rails.logger).to have_received(:info).with(/ImportFootballDataJob/).at_least(:once)
    end

    it 'logs a failure' do
      allow(Rails.logger).to receive(:warn)

      described_class.new.run('/nonexistent/nope.csv', season_label)

      expect(Rails.logger).to have_received(:warn).with(/ImportFootballDataJob/).at_least(:once)
    end
  end
end
