require 'rails_helper'

# The reader is the lowest layer of the import pipeline: it turns a CSV file
# into raw rows keyed by the file's own header line. It deliberately knows
# nothing about football — it only guarantees that the file exists, is parseable
# and carries the columns the caller says it needs. That keeps "the shape of the
# file" separate from "what the columns mean" (which belongs to the adapter).
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

  describe 'error handling' do
    it 'raises FileNotFound for a path that does not exist' do
      expect {
        described_class.read('/nonexistent/does_not_exist.csv')
      }.to raise_error(Import::CsvReader::FileNotFound)
    end
  end
end
