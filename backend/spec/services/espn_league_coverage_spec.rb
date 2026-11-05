require "rails_helper"

# Slug <-> competition code mapping for ESPN.
#
# WHY THIS IS ITS OWN SPEC
# ------------------------
# `EspnLeagueCoverage::VERIFIED` is keyed CODE => SLUG ("E0" => "eng.1"). Reading
# it as slug => code returns nil for every real slug, which is exactly what made
# the first version of `EspnLeagueSeason.for_league` raise UnknownLeague for
# "eng.1". The inversion is a property of the map, so it is tested on the map
# rather than only through a caller that happens to use it.
RSpec.describe EspnLeagueCoverage do
  describe ".code_for_slug" do
    it "resolves the Premier League slug" do
      expect(described_class.code_for_slug("eng.1")).to eq("E0")
    end

    it "resolves the Championship slug, distinctly from the Premier League" do
      expect(described_class.code_for_slug("eng.2")).to eq("E1")
      expect(described_class.code_for_slug("eng.1")).not_to eq(described_class.code_for_slug("eng.2"))
    end

    it "resolves the Scottish Premiership slug" do
      expect(described_class.code_for_slug("sco.1")).to eq("SC0")
    end

    it "returns nil for a slug that is not mapped" do
      expect(described_class.code_for_slug("eng.99")).to be_nil
      expect(described_class.code_for_slug("")).to be_nil
      expect(described_class.code_for_slug(nil)).to be_nil
    end

    it "is the exact inverse of slug_for for every mapped code" do
      described_class::VERIFIED.each do |code, slug|
        expect(described_class.code_for_slug(slug)).to eq(code)
        expect(described_class.slug_for(code)).to eq(slug)
      end
    end

    it "maps no slug to more than one code" do
      slugs = described_class::VERIFIED.values
      expect(slugs).to eq(slugs.uniq)
    end
  end
end
