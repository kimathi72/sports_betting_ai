require 'rails_helper'

# The adapter is the only place that knows football-data.co.uk's column names and
# date format. It turns one raw CSV row into a normalized Import::MatchRow, or
# into a row-level error. Everything downstream (resolution, persistence) works
# with the normalized representation, so a second provider only needs a second
# adapter — the importer never changes.
#
# These specs run entirely against a local fixture; no network access is used.
RSpec.describe Import::FootballDataCoUkAdapter do
  let(:fixture_path) do
    Rails.root.join('..', 'data', 'fixtures', 'football_data_premier_league_sample.csv').to_s
  end

  # The raw rows as the reader hands them over — strings, keyed by header text.
  let(:rows) { Import::CsvReader.read(fixture_path) }

  describe '.parse_row' do
    it 'normalizes a valid row into predictable fields' do
      row = described_class.parse_row(rows.first)

      expect(row).to be_a(Import::MatchRow)
      expect(row).to have_attributes(
        provider: 'football_data',
        competition_code: 'E0',
        home_team_name: 'Manchester United',
        away_team_name: 'Fulham',
        home_score: 1,
        away_score: 0,
        status: 'completed'
      )
      expect(row.kickoff_at).to eq(Time.utc(2024, 8, 16, 12, 30))
    end

    it 'parses the source date and time into a UTC instant' do
      row = described_class.parse_row(rows[1])

      expect(row.kickoff_at).to eq(Time.utc(2024, 8, 17, 15, 0))
    end

    it 'exposes a stable provider key for the fixture' do
      row = described_class.parse_row(rows.first)

      expect(row.provider_key).to eq('E0|16/08/2024|12:30|Manchester United|Fulham')
    end

    it 'maps FTR to the completed status and keeps both scores' do
      row = described_class.parse_row(rows[4])

      expect(row.status).to eq('completed')
      expect(row.home_score).to eq(1)
      expect(row.away_score).to eq(1)
    end
  end

  describe 'row-level rejection' do
    it 'rejects a row with a missing home team name' do
      result = described_class.parse(rows.first.merge('HomeTeam' => ''))

      expect(result).not_to be_success
      expect(result.error).to match(/home team/i)
    end

    it 'rejects a row with a missing away team name' do
      result = described_class.parse(rows.first.merge('AwayTeam' => '  '))

      expect(result).not_to be_success
      expect(result.error).to match(/away team/i)
    end

    it 'rejects a row with an invalid date' do
      result = described_class.parse(rows.first.merge('Date' => 'not-a-date'))

      expect(result).not_to be_success
      expect(result.error).to match(/date/i)
    end

    it 'rejects a row whose final scores are not non-negative integers' do
      result = described_class.parse(rows.first.merge('FTHG' => '-1'))

      expect(result).not_to be_success
      expect(result.error).to match(/score/i)
    end

    it 'rejects a row with a non-numeric score' do
      result = described_class.parse(rows.first.merge('FTAG' => 'x'))

      expect(result).not_to be_success
      expect(result.error).to match(/score/i)
    end

    it 'rejects a row where only one score is present' do
      result = described_class.parse(rows.first.merge('FTAG' => ''))

      expect(result).not_to be_success
      expect(result.error).to match(/score/i)
    end

    it 'does not raise for an unexpected extra column' do
      result = described_class.parse(rows.first.merge('Referee' => 'A. Taylor'))

      expect(result).to be_success
    end
  end

  describe 'required columns' do
    it 'declares the columns it needs from the file' do
      expect(described_class::REQUIRED_COLUMNS).to contain_exactly(
        'Div', 'Date', 'Time', 'HomeTeam', 'AwayTeam', 'FTHG', 'FTAG', 'FTR'
      )
    end
  end

  describe '.parse_all' do
    it 'returns one result per data row, in file order' do
      results = described_class.parse_all(rows)

      expect(results.length).to eq(7)
      expect(results).to all(be_a(Import::RowResult))
      expect(results.first.row.home_team_name).to eq('Manchester United')
      expect(results.last.row.home_team_name).to eq('Brentford')
    end

    it 'collects row-level errors without aborting the whole parse' do
      bad = rows.first.merge('Date' => 'nope')

      results = described_class.parse_all([rows[0], bad])

      expect(results.map(&:success?)).to eq([true, false])
      expect(results[1].error).to match(/date/i)
      expect(results[1].index).to eq(1)
    end
  end
end
