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

    # The key is the match identity, so it is rendered from parsed values and
    # normalised names rather than echoing raw file text. See 'natural match key'.
    it 'exposes a stable provider key for the fixture' do
      row = described_class.parse_row(rows.first)

      expect(row.provider_key).to eq('E0|2024-08-16|12:30|manchester united|fulham')
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
        'Div', 'Date', 'HomeTeam', 'AwayTeam', 'FTHG', 'FTAG', 'FTR'
      )
    end

    # Time is optional: seeking before 2019/20 publish no kickoff time, and
    # rejecting those files would make real history permanently unreachable.
    # See optional_time_column_spec.rb for the behaviour.
    it 'treats Time as optional' do
      expect(described_class::OPTIONAL_COLUMNS).to contain_exactly('Time')
      expect(described_class::REQUIRED_COLUMNS).not_to include('Time')
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

  # The full-time-result policy, stated explicitly. FTR is the provider's
  # outcome code; it decides whether a row asserts a finished result, a
  # postponed fixture or a fixture that has not been played yet. Getting this
  # wrong silently corrupts results, so every branch is pinned here.
  describe 'FTR data-integrity policy' do
    let(:valid_row) do
      {
        'Div' => 'E0', 'Date' => '16/08/2024', 'Time' => '12:30',
        'HomeTeam' => 'Manchester United', 'AwayTeam' => 'Fulham',
        'FTHG' => '1', 'FTAG' => '0', 'FTR' => 'H'
      }
    end

    %w[H D A].each do |code|
      it "maps FTR=#{code} with valid scores to a completed match" do
        result = described_class.parse(valid_row.merge('FTR' => code))

        expect(result).to be_success
        expect(result.row.status).to eq('completed')
        expect(result.row.home_score).to eq(1)
        expect(result.row.away_score).to eq(0)
      end
    end

    it 'maps FTR=P to postponed with no result, not completed' do
      result = described_class.parse(valid_row.merge('FTR' => 'P', 'FTHG' => '', 'FTAG' => ''))

      expect(result).to be_success
      expect(result.row.status).to eq('postponed')
      expect(result.row.home_score).to be_nil
      expect(result.row.away_score).to be_nil
    end

    it 'rejects FTR=P when scores are also present' do
      result = described_class.parse(valid_row.merge('FTR' => 'P'))

      expect(result).not_to be_success
      expect(result.error).to match(/postponed/i)
    end

    it 'maps a blank FTR with blank scores to scheduled' do
      result = described_class.parse(valid_row.merge('FTR' => '', 'FTHG' => '', 'FTAG' => ''))

      expect(result).to be_success
      expect(result.row.status).to eq('scheduled')
      expect(result.row.home_score).to be_nil
      expect(result.row.away_score).to be_nil
    end

    it 'rejects a blank FTR that carries scores, never discarding them' do
      result = described_class.parse(valid_row.merge('FTR' => ''))

      expect(result).not_to be_success
      expect(result.error).to match(/FTR|full-time/i)
    end

    it 'rejects a blank FTR that carries only one score' do
      result = described_class.parse(valid_row.merge('FTR' => '', 'FTAG' => ''))

      expect(result).not_to be_success
    end

    it 'rejects a completed code with missing scores' do
      result = described_class.parse(valid_row.merge('FTHG' => '', 'FTAG' => ''))

      expect(result).not_to be_success
      expect(result.error).to match(/score/i)
    end

    it 'rejects an unknown FTR value' do
      result = described_class.parse(valid_row.merge('FTR' => 'X'))

      expect(result).not_to be_success
      expect(result.error).to match(/FTR|unknown/i)
    end

    it 'rejects a lowercase FTR rather than silently accepting it' do
      result = described_class.parse(valid_row.merge('FTR' => 'h'))

      expect(result).not_to be_success
    end
  end

  describe 'required identity fields' do
    let(:valid_row) do
      {
        'Div' => 'E0', 'Date' => '16/08/2024', 'Time' => '12:30',
        'HomeTeam' => 'Manchester United', 'AwayTeam' => 'Fulham',
        'FTHG' => '1', 'FTAG' => '0', 'FTR' => 'H'
      }
    end

    it 'rejects a blank competition code' do
      result = described_class.parse(valid_row.merge('Div' => '  '))

      expect(result).not_to be_success
      expect(result.error).to match(/competition|Div/i)
    end

    it 'rejects a blank home team name' do
      expect(described_class.parse(valid_row.merge('HomeTeam' => ' '))).not_to be_success
    end

    it 'rejects a blank away team name' do
      expect(described_class.parse(valid_row.merge('AwayTeam' => ''))).not_to be_success
    end

    it 'rejects a missing kickoff time instead of inventing midnight' do
      result = described_class.parse(valid_row.merge('Time' => ''))

      expect(result).not_to be_success
      expect(result.error).to match(/time/i)
    end

    it 'rejects a malformed kickoff time' do
      expect(described_class.parse(valid_row.merge('Time' => '3pm'))).not_to be_success
    end

    it 'rejects an out-of-range kickoff time' do
      expect(described_class.parse(valid_row.merge('Time' => '25:70'))).not_to be_success
    end
  end

  # Date.strptime('%d/%m/%Y') happily parses '16/08/24' as the year 24 AD.
  # A two-digit year is ambiguous, so it is rejected rather than imported as 0024.
  describe 'date parsing' do
    let(:valid_row) do
      {
        'Div' => 'E0', 'Date' => '16/08/2024', 'Time' => '12:30',
        'HomeTeam' => 'Manchester United', 'AwayTeam' => 'Fulham',
        'FTHG' => '1', 'FTAG' => '0', 'FTR' => 'H'
      }
    end

    it 'never reads a two-digit year as year 0024' do
      # The 2016/17 file really does write dd/mm/yy, so the shape is accepted —
      # but it is expanded to 20xx explicitly, never handed to strptime (which
      # would read "24" as the year 24 AD). See two_digit_year_spec.rb.
      result = described_class.parse(valid_row.merge('Date' => '16/08/24'))

      expect(result).to be_success
      expect(result.row.kickoff_at.year).to eq(2024)
      expect(result.row.kickoff_at.year).not_to eq(24)
    end

    it 'rejects an impossible calendar date' do
      expect(described_class.parse(valid_row.merge('Date' => '31/02/2024'))).not_to be_success
    end

    it 'rejects a blank date' do
      expect(described_class.parse(valid_row.merge('Date' => ''))).not_to be_success
    end

    it 'accepts a valid four-digit-year date' do
      result = described_class.parse(valid_row.merge('Date' => '01/01/2025'))

      expect(result).to be_success
      expect(result.row.kickoff_at).to eq(Time.utc(2025, 1, 1, 12, 30))
    end
  end

  # The provider publishes no match id, so the natural key IS the match
  # identity. Identity must not change because of cosmetic whitespace or case.
  describe 'natural match key' do
    let(:valid_row) do
      {
        'Div' => 'E0', 'Date' => '16/08/2024', 'Time' => '12:30',
        'HomeTeam' => 'Manchester United', 'AwayTeam' => 'Fulham',
        'FTHG' => '1', 'FTAG' => '0', 'FTR' => 'H'
      }
    end

    it 'is unaffected by surrounding or repeated whitespace in team names' do
      tidy = described_class.parse_row(valid_row)
      messy = described_class.parse_row(
        valid_row.merge('HomeTeam' => '  Manchester   United ', 'AwayTeam' => 'FULHAM')
      )

      expect(messy.provider_key).to eq(tidy.provider_key)
    end

    it 'is unaffected by a single-digit hour in the kickoff time' do
      padded = described_class.parse_row(valid_row.merge('Time' => '09:05'))
      loose = described_class.parse_row(valid_row.merge('Time' => '9:05'))

      expect(loose.kickoff_at).to eq(padded.kickoff_at)
      expect(loose.provider_key).to eq(padded.provider_key)
    end

    it 'uses the calendar date rather than the raw date string' do
      from_padded = described_class.parse_row(valid_row.merge('Date' => '01/01/2025'))
      from_loose = described_class.parse_row(valid_row.merge('Date' => '1/1/2025'))

      expect(from_loose).to be_a(Import::MatchRow)
      expect(from_loose.provider_key).to eq(from_padded.provider_key)
    end

    it 'is distinct for different fixtures' do
      a = described_class.parse_row(valid_row)
      b = described_class.parse_row(valid_row.merge('AwayTeam' => 'Chelsea'))

      expect(a.provider_key).not_to eq(b.provider_key)
    end
  end

  describe 'display names versus normalized identity' do
    it 'preserves the source display name verbatim' do
      row = described_class.parse_row(
        rows.first.merge('HomeTeam' => 'Brighton & Hove Albion')
      )

      expect(row.home_team_name).to eq('Brighton & Hove Albion')
    end
  end

  describe 'season label' do
    it 'never infers a season from the kickoff date' do
      row = described_class.parse_row(rows.first)

      expect(row.season_label).to be_nil
    end
  end

  describe 'MatchRow immutability' do
    it 'is frozen once constructed' do
      row = described_class.parse_row(rows.first)

      expect(row).to be_frozen
    end

    it 'has a frozen provider key' do
      row = described_class.parse_row(rows.first)

      expect(row.provider_key).to be_frozen
    end

    it 'cannot be mutated after construction' do
      row = described_class.parse_row(rows.first)

      expect { row.status = 'cancelled' }.to raise_error(FrozenError)
    end
  end

  describe 'the mixed-status fixture' do
    let(:mixed_path) do
      Rails.root.join('..', 'data', 'fixtures',
                      'football_data_premier_league_sample_mixed_statuses.csv').to_s
    end

    it 'parses every row successfully' do
      results = described_class.parse_all(Import::CsvReader.read(mixed_path))

      expect(results.map(&:success?)).to all(be(true))
    end

    it 'covers completed, postponed and scheduled rows' do
      rows = described_class.parse_all(Import::CsvReader.read(mixed_path)).map(&:row)

      expect(rows.map(&:status)).to eq(
        %w[completed completed completed completed postponed scheduled scheduled]
      )
    end

    it 'keeps scores only on completed rows' do
      rows = described_class.parse_all(Import::CsvReader.read(mixed_path)).map(&:row)

      expect(rows.select { |row| row.status == 'completed' })
        .to all(satisfy { |row| row.home_score.is_a?(Integer) && row.away_score.is_a?(Integer) })
      expect(rows.reject { |row| row.status == 'completed' })
        .to all(satisfy { |row| row.home_score.nil? && row.away_score.nil? })
    end
  end
end
