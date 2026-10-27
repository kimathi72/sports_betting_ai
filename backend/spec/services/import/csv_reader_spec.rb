require 'rails_helper'

# The reader is the lowest layer of the import pipeline: it turns a CSV file
# into raw rows keyed by the file's own header line. It deliberately knows
# nothing about football — it only guarantees that the file exists, is parseable
# and carries the columns the caller says it needs. That keeps "the shape of the
# file" separate from "what the columns mean" (which belongs to the adapter).
#
# Failure modes are distinct types so a caller can react differently:
#   FileNotFound   — the path does not exist
#   EmptyFile      — the file exists but has no content at all
#   MissingHeaders — the header line exists but lacks required columns
#   MalformedCsv   — CSV syntax could not be parsed
# Blank lines are dropped, and the index returned to the adapter is a data-row
# index (0-based), so error messages number rows as the reader delivered them.
RSpec.describe Import::CsvReader do
  # A fixture that mirrors football-data.co.uk's real Premier League export.
  # Local only — the specs must never touch the network.
  let(:fixture_path) do
    Rails.root.join('..', 'data', 'fixtures', 'football_data_premier_league_sample.csv').to_s
  end

  describe '.read' do
    it 'returns one hash per data row, keyed by the actual header names' do
      rows = described_class.read(fixture_path)

      expect(rows.length).to eq(7)
      expect(rows.first).to include(
        'Div' => 'E0',
        'Date' => '16/08/2024',
        'HomeTeam' => 'Manchester United',
        'AwayTeam' => 'Fulham',
        'FTHG' => '1',
        'FTAG' => '0',
        'FTR' => 'H'
      )
    end

    it 'does not include the header row in the returned rows' do
      rows = described_class.read(fixture_path)

      expect(rows.map { |row| row['HomeTeam'] }).not_to include('HomeTeam')
    end

    it 'preserves row order from the file' do
      rows = described_class.read(fixture_path)

      expect(rows.first['HomeTeam']).to eq('Manchester United')
      expect(rows.last['HomeTeam']).to eq('Brentford')
    end

    it 'skips fully blank lines' do
      Tempfile.create(['blank_lines', '.csv']) do |file|
        file.write("Div,HomeTeam\n")
        file.write("E0,Arsenal\n")
        file.write("\n")
        file.write("E0,Chelsea\n")
        file.flush

        rows = described_class.read(file.path)

        expect(rows.length).to eq(2)
      end
    end
  end

  describe '.read with required columns' do
    it 'returns rows when every required column is present' do
      expect {
        described_class.read(fixture_path, required: %w[Div HomeTeam AwayTeam FTHG FTAG FTR])
      }.not_to raise_error
    end

    it 'raises MissingHeaders listing the absent columns' do
      Tempfile.create(['missing', '.csv']) do |file|
        file.write("Div,HomeTeam\n")
        file.write("E0,Arsenal\n")
        file.flush

        expect {
          described_class.read(file.path, required: %w[Div AwayTeam FTHG])
        }.to raise_error(Import::CsvReader::MissingHeaders) { |error|
          expect(error.message).to include('AwayTeam', 'FTHG')
          expect(error.message).not_to include('Div')
        }
      end
    end
  end

  describe 'encoding' do
    it 'strips a UTF-8 byte-order mark so the first header is usable' do
      Tempfile.create(['bom', '.csv']) do |file|
        file.write("\xEF\xBB\xBFDiv,HomeTeam\n")
        file.write("E0,Arsenal\n")
        file.flush

        rows = described_class.read(file.path, required: %w[Div])

        expect(rows.first['Div']).to eq('E0')
        expect(rows.first.keys).to include('Div')
        expect(rows.first.keys.first).not_to start_with("\xEF\xBB\xBF")
      end
    end

    it 'decodes UTF-8 team names without corrupting them' do
      Tempfile.create(['utf8', '.csv']) do |file|
        file.write("Div,HomeTeam\n")
        file.write("E0,Atlético Madrid\n")
        file.flush

        rows = described_class.read(file.path)

        expect(rows.first['HomeTeam']).to eq('Atlético Madrid')
        expect(rows.first['HomeTeam'].valid_encoding?).to be(true)
      end
    end
  end

  describe 'empty and headerless files' do
    it 'raises EmptyFile for a zero-byte file' do
      Tempfile.create(['empty', '.csv']) do |file|
        file.flush

        expect {
          described_class.read(file.path, required: %w[Div])
        }.to raise_error(Import::CsvReader::EmptyFile)
      end
    end

    it 'raises EmptyFile for a file containing only whitespace' do
      Tempfile.create(['blank', '.csv']) do |file|
        file.write("\n\n")
        file.flush

        expect {
          described_class.read(file.path)
        }.to raise_error(Import::CsvReader::EmptyFile)
      end
    end

    it 'raises MissingHeaders when the header line is absent but data exists' do
      Tempfile.create(['headerless', '.csv']) do |file|
        file.write("E0,Arsenal\n")
        file.flush

        expect {
          described_class.read(file.path, required: %w[Div HomeTeam])
        }.to raise_error(Import::CsvReader::MissingHeaders)
      end
    end
  end

  describe 'malformed CSV' do
    it 'raises MalformedCsv, not MissingHeaders, for a syntax error' do
      Tempfile.create(['malformed', '.csv']) do |file|
        file.write("Div,HomeTeam\n")
        file.write("E0,\"unterminated\n")
        file.flush

        expect {
          described_class.read(file.path, required: %w[Div HomeTeam])
        }.to raise_error(Import::CsvReader::MalformedCsv) { |error|
          expect(error).not_to be_a(Import::CsvReader::MissingHeaders)
          expect(error.message).to match(/malformed|unterminated/i)
        }
      end
    end

    it 'does not relabel unrelated IO failures as parsing errors' do
      # A directory is not a CSV; that is a caller mistake, not malformed data.
      expect {
        described_class.read(Dir.tmpdir)
      }.to raise_error(Import::CsvReader::FileNotFound)
    end
  end

  describe 'error handling' do
    it 'raises FileNotFound for a path that does not exist' do
      expect {
        described_class.read('/nonexistent/does_not_exist.csv')
      }.to raise_error(Import::CsvReader::FileNotFound)
    end

    it 'exposes distinct error classes that are all StandardError' do
      [
        Import::CsvReader::FileNotFound,
        Import::CsvReader::EmptyFile,
        Import::CsvReader::MissingHeaders,
        Import::CsvReader::MalformedCsv,
      ].each do |klass|
        expect(klass.ancestors).to include(StandardError)
      end
    end
  end
end
