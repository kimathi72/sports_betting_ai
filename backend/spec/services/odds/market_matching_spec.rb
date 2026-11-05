require "rails_helper"

# Mapping a provider's market/selection names onto OUR five markets.
#
# WHY THIS IS A SEPARATE, TESTED UNIT
# -----------------------------------
# A mis-mapped selection does not fail loudly. It produces a paper bet on the wrong
# outcome, settles it against the wrong result, and reports a plausible ROI. The
# mapping is therefore explicit, closed, and refuses anything it does not recognise
# rather than guessing from a substring.
RSpec.describe Odds::MarketMatching do
  describe "market names" do
    it "maps the canonical names to themselves" do
      %w[1x2 over_under_2.5 btts double_chance].each do |market|
        expect(described_class.market(market)).to eq(market)
      end
    end

    it "maps football-data column families" do
      expect(described_class.market("1X2")).to eq("1x2")
      expect(described_class.market("O/U 2.5")).to eq("over_under_2.5")
      expect(described_class.market("BTTS")).to eq("btts")
      expect(described_class.market("DC")).to eq("double_chance")
    end

    it "refuses correct score, which has no fixed selection set" do
      expect { described_class.market("correct_score") }.to raise_error(Odds::MarketMatching::UnsupportedMarket, /correct score/i)
    end

    it "refuses an unknown market instead of guessing" do
      expect { described_class.market("asian_handicap") }.to raise_error(Odds::MarketMatching::UnsupportedMarket)
    end
  end

  describe "selections" do
    it "maps 1X2 provider labels onto H/D/A" do
      expect(described_class.selection("1x2", "Home")).to eq("H")
      expect(described_class.selection("1x2", "Draw")).to eq("D")
      expect(described_class.selection("1x2", "Away")).to eq("A")
      expect(described_class.selection("1x2", "H")).to eq("H")
    end

    it "maps over/under labels onto the canonical lower-case keys" do
      expect(described_class.selection("over_under_2.5", "Over 2.5")).to eq("over")
      expect(described_class.selection("over_under_2.5", "Under 2.5")).to eq("under")
    end

    it "maps BTTS labels onto yes/no" do
      expect(described_class.selection("btts", "Yes")).to eq("yes")
      expect(described_class.selection("btts", "No")).to eq("no")
    end

    it "maps double chance labels onto 1x/x2/12" do
      expect(described_class.selection("double_chance", "Home or Draw")).to eq("1x")
      expect(described_class.selection("double_chance", "Draw or Away")).to eq("x2")
      expect(described_class.selection("double_chance", "Home or Away")).to eq("12")
    end

    it "refuses a selection that belongs to another market" do
      expect { described_class.selection("btts", "Home") }.to raise_error(Odds::MarketMatching::UnsupportedSelection)
    end
  end

  describe "a complete market" do
    it "accepts a full 1X2 set" do
      expect(described_class.complete?("1x2", %w[H D A])).to be(true)
    end

    it "rejects a partial set" do
      expect(described_class.complete?("1x2", %w[H D])).to be(false)
    end

    it "rejects a set with an extra selection" do
      expect(described_class.complete?("btts", %w[yes no maybe])).to be(false)
    end
  end

  describe "football-data column names" do
    it "recognises a bookmaker's 1X2 triple" do
      expect(described_class.football_data_columns("B365")["1x2"]).to eq(
        "H" => "B365H", "D" => "B365D", "A" => "B365A"
      )
    end

    it "recognises the closing 1X2 triple" do
      expect(described_class.football_data_columns("B365", closing: true)["1x2"]).to eq(
        "H" => "B365CH", "D" => "B365CD", "A" => "B365CA"
      )
    end

    it "recognises over/under 2.5" do
      expect(described_class.football_data_columns("B365")["over_under_2.5"]).to eq("over" => "B365>2.5", "under" => "B365<2.5")
    end

    it "reports no BTTS columns, because football-data does not publish them" do
      expect(described_class.football_data_columns("B365")).not_to have_key("btts")
    end
  end
end
