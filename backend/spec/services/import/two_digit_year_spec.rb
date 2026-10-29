require 'rails_helper'

# One historical season file (2016/17) writes dates as `dd/mm/yy` — the only
# season that does, but real. Reaching that history means accepting that shape.
#
# Accepting it must NOT reintroduce the bug the strict parser was written to
# prevent: Ruby's Date.strptime("%d/%m/%Y") happily reads "13/08/16" as the year
# 16 AD. So a two-digit year is never passed to strptime as a year. It is
# expanded with an explicit, documented window first and then validated like any
# other date.
#
# The window: the platform's earliest season is 2016/17, and a Premier League
# season only spans one calendar year boundary. A two-digit year in 00..99 is
# therefore resolved as 20xx. This is a rule, not a guess — and a value that
# falls outside the plausible range is still rejected.
RSpec.describe Import::FootballDataCoUkAdapter, 'two-digit years' do
  def row(date, time: '15:00')
    {
      'Div' => 'E0', 'Date' => date, 'Time' => time,
      'HomeTeam' => 'Burnley', 'AwayTeam' => 'Swansea',
      'FTHG' => '0', 'FTAG' => '1', 'FTR' => 'A'
    }
  end

  it 'expands a two-digit year into the 2000s' do
    result = described_class.parse(row('13/08/16'))

    expect(result).to be_success
    expect(result.row.kickoff_at).to eq(Time.utc(2016, 8, 13, 15, 0))
  end

  it 'never reads a two-digit year as an ancient date' do
    result = described_class.parse(row('13/08/16'))

    expect(result.row.kickoff_at.year).to eq(2016)
    expect(result.row.kickoff_at.year).not_to eq(16)
  end

  it 'still accepts a four-digit year' do
    result = described_class.parse(row('13/08/2016'))

    expect(result).to be_success
    expect(result.row.kickoff_at).to eq(Time.utc(2016, 8, 13, 15, 0))
  end

  it 'gives the same instant for both year shapes' do
    two = described_class.parse(row('13/08/16')).row
    four = described_class.parse(row('13/08/2016')).row

    expect(two.kickoff_at).to eq(four.kickoff_at)
    expect(two.provider_key).to eq(four.provider_key)
  end

  it 'rejects an impossible calendar date written with a two-digit year' do
    result = described_class.parse(row('31/02/16'))

    expect(result).not_to be_success
  end

  it 'rejects three-digit or other malformed year shapes' do
    expect(described_class.parse(row('13/08/166'))).not_to be_success
    expect(described_class.parse(row('13/08/'))).not_to be_success
  end

  it 'rejects a two-digit year that resolves before the platform history begins' do
    # 13/08/15 would be 2015, before any supported season. Accepting it would
    # silently place a fixture outside every known season.
    result = described_class.parse(row('13/08/15'))

    expect(result).not_to be_success
    expect(result.error).to match(/date|year/i)
  end

  it 'records the kickoff time as known for these rows' do
    expect(described_class.parse(row('13/08/16')).row.time_known).to be(true)
  end
end
