require "rails_helper"

# The competition catalogue decides what a user reads in the app, so it is pinned
# rather than treated as incidental data: every entry must carry a real name, a
# country the region filter can group by, and a region the mobile filter offers.
RSpec.describe CompetitionCatalogue do
  describe "entries" do
    it "names every competition the import pipeline supports" do
      Import::CsvDownloader::SUPPORTED_DIVISIONS.each do |code|
        entry = described_class.lookup(code)
        expect(entry).to be_present, "#{code} is downloadable but absent from the catalogue"
      end
    end

    it "gives every entry a non-blank name and country" do
      described_class::ENTRIES.each do |code, entry|
        expect(entry.name).to be_present, "#{code} has no name"
        expect(entry.country).to be_present, "#{code} has no country"
      end
    end

    it "uses only regions the mobile filter offers" do
      described_class::ENTRIES.each do |code, entry|
        expect(described_class::REGIONS).to have_key(entry.region), "#{code}: unknown region"
      end
    end

    it "has unique names, because competition identity is the name" do
      names = described_class::ENTRIES.values.map(&:name)
      expect(names.uniq.length).to eq(names.length)
    end
  end

  describe ".canonical_name" do
    it "translates an import code into a readable name" do
      expect(described_class.canonical_name("E1")).to eq("Championship")
      expect(described_class.canonical_name("SP1")).to eq("La Liga")
    end

    it "accepts a provider-prefixed key" do
      expect(described_class.canonical_name("football_data E0")).to eq("Premier League")
      expect(described_class.canonical_name("espn eng.1")).to eq("eng.1")
    end

    it "never invents a name for a code it does not know" do
      expect(described_class.canonical_name("ZZ9")).to eq("ZZ9")
    end
  end

  describe ".backfill!" do
    it "repairs a name generated from a provider code" do
      competition = Competition.create!(name: "football_data competition E1", code: "E1")

      described_class.backfill!

      competition.reload
      expect(competition.name).to eq("Championship")
      expect(competition.country).to eq("England")
    end

    it "repairs a row whose code is missing by reading the old name" do
      competition = Competition.create!(name: "football_data competition SP1")

      described_class.backfill!

      expect(competition.reload.name).to eq("La Liga")
    end

    it "never overwrites a name a human chose" do
      competition = Competition.create!(name: "Primera Division", code: "SP1", country: "Spain")

      described_class.backfill!

      expect(competition.reload.name).to eq("Primera Division")
    end

    it "fills in a missing country without touching the name" do
      competition = Competition.create!(name: "La Liga", code: "SP1")

      described_class.backfill!

      expect(competition.reload.country).to eq("Spain")
      expect(competition.name).to eq("La Liga")
    end

    it "leaves a competition it does not recognise untouched" do
      competition = Competition.create!(name: "football_data competition ZZ9", code: "ZZ9")

      described_class.backfill!

      expect(competition.reload.name).to eq("football_data competition ZZ9")
    end

    it "is idempotent" do
      Competition.create!(name: "football_data competition D1", code: "D1")
      described_class.backfill!
      second = described_class.backfill!

      expect(second).to be_empty
    end
  end
end
