require 'rails_helper'
require 'rake'

# The operator-facing entry point for a single manual import.
#
# Rake tasks are hard to test and easy to litter with logic; the behaviour lives
# here and the task is a thin wrapper. This object validates arguments BEFORE the
# importer runs, so a typo cannot start a guessed import, and it produces a
# concise, secret-free report plus an exit status the shell can act on.
RSpec.describe Import::Command do
  let(:fixture_path) do
    Rails.root.join('..', 'data', 'fixtures', 'football_data_premier_league_sample.csv').to_s
  end

  let(:season_label) { '2024/25' }

  def command(path = fixture_path, season: season_label)
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

    it 'rejects a nonexistent file before importing' do
      result = command('/nonexistent/nope.csv').call

      expect(result).to be_failure
      expect(result.output).to match(/not found|no such file/i)
      expect(Match.count).to eq(0)
    end

    it 'rejects a directory' do
      expect(command(Dir.tmpdir).call).to be_failure
    end

    it 'rejects a relative path, which is ambiguous inside a container' do
      result = command('data/fixtures/football_data_premier_league_sample.csv').call

      expect(result).to be_failure
      expect(result.output).to match(/absolute/i)
    end

    it 'requires an explicit season label' do
      result = command(fixture_path, season: '').call

      expect(result).to be_failure
      expect(result.output).to match(/season/i)
      expect(Match.count).to eq(0)
    end

    it 'rejects a season label it cannot recognise' do
      result = command(fixture_path, season: 'summer').call

      expect(result).to be_failure
      expect(result.output).to match(/season/i)
    end

    it 'does not guess a season from the file contents' do
      # A valid file must still be refused when the operator gave no label.
      expect(command(fixture_path, season: nil).call).to be_failure
      expect(Season.count).to eq(0)
    end
  end

  describe 'a successful import' do
    it 'exits zero' do
      expect(command.call.exit_status).to eq(0)
    end

    it 'reports the counts from the importer' do
      result = command.call

      expect(result.success?).to be(true)
      expect(result.output).to include('7 rows')
      expect(result.output).to include('7 created')
    end

    it 'mentions the season and file so the run is auditable' do
      result = command.call

      expect(result.output).to include('2024/25')
      expect(result.output).to include('football_data_premier_league_sample.csv')
    end

    it 'actually imports the data' do
      command.call

      expect(Match.count).to eq(7)
    end
  end

  describe 'a rejected import' do
    let(:bad_path) do
      file = Tempfile.new(['bad', '.csv'])
      file.write("Div,Date,Time,HomeTeam,AwayTeam,FTHG,FTAG,FTR\n")
      file.write("E0,16/08/2024,12:30,Manchester United,Fulham,1,0,H\n")
      file.write("E0,17/08/2024,15:00,,Chelsea,1,0,H\n")
      file.close
      file.path
    end

    after { File.delete(bad_path) if File.exist?(bad_path) }

    it 'exits non-zero' do
      expect(command(bad_path).call.exit_status).to eq(1)
    end

    it 'prints the actionable row error' do
      result = command(bad_path).call

      # Row numbering is one-based over data rows (header excluded), so the
      # second data row is row 2.
      expect(result.output).to match(/row 2:/i)
      expect(result.output).to match(/home team/i)
    end

    it 'does not leave partial data behind' do
      command(bad_path).call

      expect(Match.count).to eq(0)
    end
  end

  describe 'output safety' do
    it 'never prints secrets, SQL or stack traces' do
      result = command('/nonexistent/nope.csv').call

      expect(result.output).not_to match(/PG::|ActiveRecord::|postgres_password|SQLSTATE/i)
    end

    it 'caps the number of printed errors so a huge file stays readable' do
      file = Tempfile.new(['many', '.csv'])
      file.write("Div,Date,Time,HomeTeam,AwayTeam,FTHG,FTAG,FTR\n")
      30.times { file.write("E0,17/08/2024,15:00,,Chelsea,1,0,H\n") }
      file.close

      begin
        result = command(file.path).call

        expect(result.output.scan(/^  row /).length).to be <= described_class::MAX_REPORTED_ERRORS
        expect(result.output).to match(/more/i)
      ensure
        File.delete(file.path)
      end
    end
  end

  describe 'the rake task' do
    before { Rails.application.load_tasks if Rake::Task.tasks.empty? }

    it 'is defined with path and season arguments' do
      task = Rake::Task['import:football_data']

      expect(task).to be_present
      expect(task.arg_names).to eq(%i[path season])
    end

    it 'fails the task when arguments are invalid' do
      expect {
        capture_task_output { Rake::Task['import:football_data'].invoke(fixture_path, '') }
      }.to raise_error(SystemExit)
    end

    it 'imports the file when arguments are valid' do
      capture_task_output { Rake::Task['import:football_data'].reenable }

      capture_task_output { Rake::Task['import:football_data'].invoke(fixture_path, season_label) }

      expect(Match.count).to eq(7)
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
