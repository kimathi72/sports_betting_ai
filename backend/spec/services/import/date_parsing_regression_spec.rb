require 'rails_helper'

# Regression: a valid four-digit `dd/mm/yyyy` date was rejected solely because its
# year preceded the platform's *earliest two-digit-year* season.
#
# The bug: the two-digit-year expansion needed a sanity floor so that "13/08/15"
# (an obviously wrong expansion) could not enter the corpus. That floor was
# applied to EVERY date, so the real 2015/16 season file — whose dates are
# legitimately in 2015 — failed with
#   "date is not a valid dd/mm/yyyy date: 08/08/2015"
# and one of eleven historical files could never be imported.
#
# The fix must keep both guarantees:
#   - `dd/mm/yyyy` is day/month/year and valid for any real calendar date
#   - a two-digit year is still expanded deliberately and sanity-checked
#
# Day/month order is asserted explicitly, because "04/05/2016" is ambiguous to a
# human reading it as mm/dd and is the classic transposition bug.
RSpec.describe Import::FootballDataCoUkAdapter, 'date parsing regression' do
  def row(date, time: '15:00')
    {
      'Div' => 'E0', 'Date' => date, 'Time' => time,
      'HomeTeam' => 'Liverpool', 'AwayTeam' => 'Stoke',
      'FTHG' => '1', 'FTAG' => '0', 'FTR' => 'H'
    }
  end

  describe 'valid four-digit dates before 2016' do
    it 'accepts 08/08/2015, the first fixture of the 2015/16 season' do
      result = described_class.parse(row('08/08/2015'))

      expect(result).to be_success
      expect(result.row.kickoff_at).to eq(Time.utc(2015, 8, 8, 15, 0))
    end

    it 'accepts every month boundary in 2015' do
      dates = %w[08/08/2015 31/12/2015 01/01/2016 29/02/2016 30/06/2016]

      results = dates.map { |date| described_class.parse(row(date)) }

      expect(results).to all(be_success)
    end

    it 'accepts a 2014 date, so the floor is not simply moved down' do
      result = described_class.parse(row('16/08/2014'))

      expect(result).to be_success
      expect(result.row.kickoff_at.year).to eq(2014)
    end

    it 'still rejects an impossible date regardless of year' do
      expect(described_class.parse(row('31/02/2015'))).not_to be_success
      expect(described_class.parse(row('00/01/2015'))).not_to be_success
      expect(described_class.parse(row('32/01/2015'))).not_to be_success
    end
  end

  describe 'day/month order' do
    it 'reads 04/05/2016 as 4 May, not 5 April' do
      result = described_class.parse(row('04/05/2016'))

      expect(result).to be_success
      expect(result.row.kickoff_at.utc.strftime('%Y-%m-%d')).to eq('2016-05-04')
    end

    it 'reads 12/03/2016 as 12 March, which a month-first parser could not' do
      result = described_class.parse(row('12/03/2016'))

      expect(result.row.kickoff_at.utc.strftime('%Y-%m-%d')).to eq('2016-03-12')
    end

    it 'reads 25/12/2015 as 25 December' do
      result = described_class.parse(row('25/12/2015'))

      expect(result.row.kickoff_at.utc.strftime('%Y-%m-%d')).to eq('2015-12-25')
    end

    it 'rejects a day greater than 12 written in an impossible month slot' do
      # 25 cannot be a month, so a transposed parse would fail; both orders must
      # agree that this date is invalid rather than silently swapping.
      expect(described_class.parse(row('25/13/2015'))).not_to be_success
    end
  end

  describe 'the two-digit-year guard still works' do
    it 'still expands a two-digit year deliberately' do
      expect(described_class.parse(row('13/08/16')).row.kickoff_at).to eq(Time.utc(2016, 8, 13, 15, 0))
    end

    it 'still rejects a malformed year shape' do
      expect(described_class.parse(row('13/08/166'))).not_to be_success
      expect(described_class.parse(row('13/08/'))).not_to be_success
    end
  end

  describe 'other supported input shapes are unchanged' do
    it 'still treats a blank date as missing' do
      result = described_class.parse(row(''))

      expect(result).not_to be_success
      expect(result.error).to match(/date is missing/i)
    end

    it 'still rejects free text' do
      expect(described_class.parse(row('not-a-date'))).not_to be_success
    end

    it 'still accepts a file with no Time column at all' do
      result = described_class.parse(row('08/08/2015').except('Time'))

      expect(result).to be_success
      expect(result.row.time_known).to be(false)
    end
  end
end
