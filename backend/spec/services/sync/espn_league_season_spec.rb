require 'rails_helper'

# ESPN season resolution, by provider league identity.
#
# THE DEFECT THIS PINS
# --------------------
# ESPN entry points resolved the target season with `Season.find_by(name: label)`.
# Season names are not unique across competitions — every competition has a
# "2026/27" — so the lookup returned whichever row came first, in practice the
# Premier League's. `espn:discover[eng.2,"2026/27"]` therefore wrote Championship
# fixtures into the Premier League's season (139 rows in the live database).
#
# THE CONTRACT
# ------------
# The input is the ESPN league slug ("eng.2"), because that is what the operator
# and the discovery job actually hold. The slug is translated to a catalogue code
# through EspnLeagueCoverage::VERIFIED and the season is then looked up scoped to
# that competition, so a season can only ever be returned for its own competition.
#
# Ambiguity is an ERROR, not nil: a caller that silently imports nothing looks
# identical to one that imported and found nothing, and that is how the original
# defect stayed invisible.
RSpec.describe Sync::EspnLeagueSeason do
  let!(:e0) { Competition.find_or_create_by!(code: 'E0') { |c| c.name = 'Premier League' } }
  let!(:e1) { Competition.find_or_create_by!(code: 'E1') { |c| c.name = 'Championship' } }
  let!(:sc0) { Competition.find_or_create_by!(code: 'SC0') { |c| c.name = 'Scottish Premiership' } }

  let!(:e0_season) do
    Season.find_or_create_by!(competition: e0, name: '2026/27') do |s|
      s.start_date = Date.new(2026, 7, 1)
      s.end_date = Date.new(2027, 6, 30)
    end
  end
  let!(:e1_season) do
    Season.find_or_create_by!(competition: e1, name: '2026/27') do |s|
      s.start_date = Date.new(2026, 7, 1)
      s.end_date = Date.new(2027, 6, 30)
    end
  end

  describe '.for_league' do
    it 'resolves eng.1 to the Premier League season' do
      expect(described_class.for_league('eng.1', '2026/27')).to eq(e0_season)
    end

    it 'resolves eng.2 to the Championship season, not the Premier League one' do
      # Both competitions have a season called 2026/27. This is the exact
      # configuration that produced the contamination.
      expect(Season.where(name: '2026/27').count).to be >= 2

      expect(described_class.for_league('eng.2', '2026/27')).to eq(e1_season)
      expect(described_class.for_league('eng.2', '2026/27')).not_to eq(e0_season)
    end

    it 'returns a season that belongs to the competition the slug maps to' do
      season = described_class.for_league('eng.2', '2026/27')
      expect(season.competition).to eq(e1)
    end
  end

  describe '.for_code' do
    it 'resolves a catalogue code directly, for callers that already know it' do
      expect(described_class.for_code('E1', '2026/27')).to eq(e1_season)
    end

    it 'does not borrow another competition\'s season' do
      # SC0 has no 2026/27 row and E0 does. The E0 season must not be offered:
      # `for_code` states the failure instead of returning something plausible.
      expect { described_class.for_code('SC0', '2026/27') }
        .to raise_error(Sync::EspnLeagueSeason::UnknownSeason) { |e| expect(e.message).to include('SC0') }
    end
  end

  describe 'failure modes' do
    it 'raises for a slug that has no verified competition mapping' do
      expect { described_class.for_league('eng.99', '2026/27') }
        .to raise_error(Sync::EspnLeagueSeason::UnknownLeague) { |e| expect(e.message).to include('eng.99') }
    end

    it 'raises when the competition is absent from this database' do
      # eng.6 is not in the verified list, so this is the unknown-league path.
      expect { described_class.for_league('eng.6', '2026/27') }
        .to raise_error(Sync::EspnLeagueSeason::UnknownLeague)
    end

    it 'raises, rather than guessing, when two seasons could match' do
      # A unique index on (competition_id, name) normally prevents this, so the
      # duplicate is injected at the query level the resolver actually makes. The
      # guarantee under test is that ambiguity is REFUSED rather than resolved by
      # taking the first row — that silent choice is what caused the incident.
      second = e1_season.dup
      second.id = e1_season.id + 10_000

      relation = Season.where(id: [e1_season.id, second.id]).order(:id)
      allow(relation).to receive(:limit).and_return([e1_season, second])
      allow(Season).to receive(:where).and_call_original
      allow(Season).to receive(:where)
        .with(competition_id: e1.id, name: '2026/27')
        .and_return(relation)

      expect { described_class.for_code('E1', '2026/27') }
        .to raise_error(Sync::EspnLeagueSeason::AmbiguousSeason) { |e| expect(e.message).to include('2026/27') }
    end

    it 'raises for a blank season label instead of returning an arbitrary row' do
      expect { described_class.for_code('E1', '') }
        .to raise_error(Sync::EspnLeagueSeason::UnknownSeason)
    end
  end

  describe '.find (compatibility)' do
    it 'still returns the competition-scoped season for a known code' do
      expect(described_class.find('E1', '2026/27')).to eq(e1_season)
    end

    it 'returns nil for a missing season rather than raising' do
      expect(described_class.find('SC0', '2026/27')).to be_nil
    end
  end
end
