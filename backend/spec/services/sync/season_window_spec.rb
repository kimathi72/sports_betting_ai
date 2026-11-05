require 'rails_helper'

# Where a season begins and ends for fixture discovery.
#
# The stray row this guards against exists in the live database: season
# "2025/26" holds a single scheduled fixture dated 2026-12-26, because ESPN was
# queried for a date range with no season boundary and the reconciler files every
# row into whichever season it was handed. That is a mislabelled fixture, which
# is worse than a missing one — a user filtering "2025/26" is shown a match from
# the 2026/27 calendar.
#
# Discovery therefore clips every window to the season it is importing.
RSpec.describe Sync::SeasonWindow do
  describe '.start_of_season' do
    it 'starts a European season in July of the first year' do
      expect(described_class.start_of_season('2026/27')).to eq(Date.new(2026, 7, 1))
    end

    it 'treats a January fixture as belonging to the season that began the previous year' do
      expect(described_class.current_label(at: Time.utc(2027, 1, 15))).to eq('2026/27')
    end
  end

  describe '.end_of_season' do
    it 'ends the season at the following May, before the next one starts' do
      expect(described_class.end_of_season('2026/27')).to eq(Date.new(2027, 6, 30))
    end

    it 'does not overlap the next season' do
      expect(described_class.end_of_season('2026/27') + 1).to eq(described_class.start_of_season('2027/28'))
    end
  end

  describe '.clip_to_season' do
    it 'returns the window unchanged when it is inside the season' do
      window = described_class.clip_to_season(
        '2026/27', from: Date.new(2026, 10, 30), to: Date.new(2026, 11, 20)
      )
      expect(window).to eq(Date.new(2026, 10, 30)..Date.new(2026, 11, 20))
    end

    it 'clips a window that straddles the end of the season' do
      window = described_class.clip_to_season(
        '2026/27', from: Date.new(2027, 5, 20), to: Date.new(2027, 8, 20)
      )
      expect(window).to eq(Date.new(2027, 5, 20)..Date.new(2027, 6, 30))
    end

    it 'returns nil when the whole window falls outside the season' do
      window = described_class.clip_to_season(
        '2025/26', from: Date.new(2026, 8, 1), to: Date.new(2026, 9, 1)
      )
      expect(window).to be_nil
    end
  end
end
