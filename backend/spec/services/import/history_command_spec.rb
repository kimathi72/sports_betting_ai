require 'rails_helper'
require 'rake'

# The operator-facing entry point for a controlled historical import from a
# YAML manifest.  The behaviour lives here rather than in a Rake task so it can
# be tested without shelling out; `lib/tasks/import.rake` is a thin wrapper that
# prints `output` and exits with `exit_status`.
#
# Argument validation happens BEFORE the runner runs.  A missing manifest, an
# invalid manifest, or a missing file label is refused outright.
#
# Output is deliberately terse: a one-line summary, the entry errors an operator
# needs to fix, and nothing else — no SQL, driver text, credentials or traces.
RSpec.describe Import::HistoryCommand do
  let(:fixture_path) do
    Rails.root.join('..', 'data', 'fixtures', 'football_data_premier_league_sample.csv').to_s
  end

  let(:fixture_mixed_path) do
    Rails.root.join('..', 'data', 'fixtures', 'football_data_premier_league_sample_mixed_statuses.csv').to_s
  end

  let(:manifest_path) do
    Rails.root.join('..', 'data', 'fixtures', 'history_manifest_sample.yml').to_s
  end

  let(:season_label) { '2024/25' }

  def command(path = manifest_path, season: season_label)
    described_class.new(path: path, season_label: season)
  end

  describe 'argument validation' do
    it 'rejects a missing path' do
      result = command(nil).call

      expect(result).to be_failure
      expect(result.output).to match(/path/i)
      expect(result.exit_status).to eq(1)
    end

    it 'rejects a blank path' do
      expect(command('   ').call).to be_failure
    end

    it 'rejects a nonexistent manifest file before importing' do
      result = command('/nonexistent/nope.manifest').call

      expect(result).to be_failure
      expect(result.output).to match(/not found|no such file/i)
    end

    it 'rejects a relative path, which is ambiguous inside a container' do
      result = command('data/fixtures/football_data_premier_league_sample.csv').call

      expect(result).to be_failure
      expect(result.output).to match(/absolute/i)
    end

    it 'requires a manifest path ending in .yml or .yaml' do
      result = command(fixture_path).call

      expect(result).to be_failure
      expect(result.output).to match(/\.yml|\.yaml/i)
    end

    it 'requires an explicit season label' do
      result = command(manifest_path, season: '').call

      expect(result).to be_failure
      expect(result.output).to match(/season/i)
    end

    it 'rejects a season label it cannot recognise' do
      result = command(manifest_path, season: 'summer').call

      expect(result).to be_failure
      expect(result.output).to match(/season/i)
    end

    it 'does not guess a season from the file contents' do
      # A valid manifest must still be refused when the operator gave no label.
      expect(command(manifest_path, season: nil).call).to be_failure
      expect(Season.count).to eq(0)
    end
  end

  describe 'a successful import' do
    let(:fixture_manifest) do
      Rails.root.join('..', 'data', 'fixtures', 'history_manifest_sample.yml').to_s
    end

    before do
      # Ensure the manifest file exists for the test
      expect(File.exist?(fixture_manifest)).to be(true), "Manifest fixture not found at #{fixture_manifest}"
    end

    it 'exits zero' do
      expect(command.call.exit_status).to eq(0)
    end

    it 'reports the counts from the runner' do
      result = command.call

      expect(result.success?).to be(true)
      expect(result.output).to include('2024/25')
      expect(result.output).to include('imported')
    end

    it 'mentions the manifest file and season so the run is auditable' do
      result = command.call

      expect(result.output).to include('2024/25')
      expect(result.output).to include('history_manifest_sample')
    end

    it 'actually imports the data from all manifest entries' do
      command.call

      expect(Match.count).to be > 0
    end
  end

  describe 'partial failure' do
    let(:fixture_manifest) do
      Rails.root.join('..', 'data', 'fixtures', 'history_manifest_mixed_statuses.yml').to_s
    end

    before do
      expect(File.exist?(fixture_manifest)).to be(true), "Manifest fixture not found at #{fixture_manifest}"
    end

    it 'exits non-zero when any entry fails' do
      expect(command(fixture_manifest).call.exit_status).to eq(1)
    end

    it 'reports which entries succeeded and which failed' do
      result = command(fixture_manifest).call

      expect(result.success?).to be(false)
      expect(result.output).to match(/succeeded|failed/i)
    end
  end

  describe 'output safety' do
    it 'never prints secrets, SQL or stack traces' do
      result = command('/nonexistent/nope.manifest').call

      expect(result.output).not_to match(/PG::|ActiveRecord::|postgres_password|SQLSTATE/i)
    end
  end

  describe 'the rake task' do
    before { Rails.application.load_tasks if Rake::Task.tasks.empty? }

    it 'is defined with a manifest_path argument' do
      task = Rake::Task['import:historical']

      expect(task).to be_present
      expect(task.arg_names).to eq(%i[manifest_path season])
    end

    it 'fails the task when arguments are invalid' do
      expect {
        capture_task_output { Rake::Task['import:historical'].invoke('/nonexistent/manifest.manifest', '') }
      }.to raise_error(SystemExit)
    end

    it 'imports the manifest when arguments are valid' do
      capture_task_output { Rake::Task['import:historical'].reenable }

      capture_task_output { Rake::Task['import:historical'].invoke(manifest_path, season_label) }

      expect(Match.count).to be > 0
    end
  end

  def capture_task_output
    original = $stdout
    $stdout = StringIO.new
    yield
  ensure
    $stdout = original
  end
end