require "rails_helper"

# Bookmaker odds -> fair probability, and probability -> expected value.
#
# WHY THESE ARE PURE FUNCTIONS
# ----------------------------
# Every number here feeds a betting decision or a reported ROI. Keeping them out of
# any ActiveRecord object means they are testable against hand-computed values, and
# it means no code path can accidentally "fix" a bookmaker's odds on the way to the
# database.
#
# THE ONE RULE THAT MATTERS MOST
# ------------------------------
# Double Chance is NOT a three-way market. 1X, X2 and 12 OVERLAP, so the sum of
# their implied probabilities is roughly 2 and dividing by it does not remove a
# margin — it invents one. A fair Double Chance price is derived from the de-vigged
# 1X2 probabilities. `de_vig` refuses the market rather than returning a plausible
# wrong number.
RSpec.describe Odds::OddsMath do
  # A real 1X2 line from football-data.co.uk, E0, with a typical ~5% overround.
  let(:one_x2) { { "H" => 2.10, "D" => 3.40, "A" => 3.60 } }

  describe "overround" do
    it "is the sum of implied probabilities" do
      # 1/2.10 + 1/3.40 + 1/3.60 = 0.476190 + 0.294118 + 0.277778
      expect(described_class.overround(one_x2)).to be_within(1e-6).of(1.048086)
    end

    it "is 1.0 for a market with no margin" do
      expect(described_class.overround("H" => 2.0, "D" => 4.0, "A" => 4.0)).to be_within(1e-12).of(1.0)
    end

    it "refuses a set of odds that is not a complete market" do
      expect { described_class.overround("H" => 2.0) }.to raise_error(ArgumentError, /at least two/)
    end
  end

  describe "de_vig" do
    it "normalises the implied probabilities to sum to 1" do
      fair = described_class.de_vig(one_x2)

      expect(fair.values.sum).to be_within(1e-12).of(1.0)
      # Hand-computed: 0.476190/1.048086, 0.294118/1.048086, 0.277778/1.048086
      expect(fair["H"]).to be_within(1e-6).of(0.454343)
      expect(fair["D"]).to be_within(1e-6).of(0.280624)
      expect(fair["A"]).to be_within(1e-6).of(0.265033)
    end

    it "keeps the favourite the favourite" do
      fair = described_class.de_vig(one_x2)

      expect(fair.max_by { |_k, v| v }.first).to eq("H")
    end

    it "is the identity on a market that carries no margin" do
      no_margin = { "H" => 2.0, "D" => 4.0, "A" => 4.0 }

      described_class.de_vig(no_margin).each do |key, value|
        expect(value).to be_within(1e-12).of(1.0 / no_margin[key])
      end
    end

    it "refuses to de-vig Double Chance, whose selections overlap" do
      dc = { "1x" => 1.30, "x2" => 1.45, "12" => 1.60 }

      expect { described_class.de_vig(dc) }.to raise_error(Odds::OddsMath::NotAPartition, /overlap/)
    end

    it "refuses a market with an impossible overround" do
      # Below 1.0 means the bookmaker would lose on every outcome; that is a parsing
      # error, not a gift, and silently accepting it would produce EV from nonsense.
      expect { described_class.de_vig("H" => 3.0, "D" => 4.0, "A" => 5.0) }
        .to raise_error(Odds::OddsMath::InvalidMarket, /overround/)
    end
  end

  describe "decimal odds validation" do
    it "accepts odds strictly greater than 1" do
      expect(described_class.valid_decimal_odds?(1.01)).to be(true)
      expect(described_class.valid_decimal_odds?("2.50")).to be(true)
    end

    it "rejects odds of 1 or less, zero, nil and junk" do
      [1.0, 0.99, 0, nil, "", "abc", -2].each do |bad|
        expect(described_class.valid_decimal_odds?(bad)).to be(false), "#{bad.inspect} should be invalid"
      end
    end
  end

  describe "expected value" do
    it "is positive when the model probability beats the fair priced probability" do
      # Model says 50%, the book prices it at 2.20 (implied 45.45%).
      expect(described_class.expected_value(model_probability: 0.50, decimal_odds: 2.20))
        .to be_within(1e-9).of(0.10)
    end

    it "is negative when the model is behind the price" do
      expect(described_class.expected_value(model_probability: 0.40, decimal_odds: 2.20))
        .to be_within(1e-9).of(-0.12)
    end

    it "is zero at a fair price" do
      expect(described_class.expected_value(model_probability: 0.5, decimal_odds: 2.0))
        .to be_within(1e-12).of(0.0)
    end

    it "is expressed per unit staked, so a stake scales it linearly" do
      one = described_class.expected_value(model_probability: 0.5, decimal_odds: 2.2)

      expect(described_class.expected_value(model_probability: 0.5, decimal_odds: 2.2, stake: 10))
        .to be_within(1e-9).of(one * 10)
    end

    it "refuses a probability outside [0,1]" do
      expect { described_class.expected_value(model_probability: 1.2, decimal_odds: 2.0) }
        .to raise_error(ArgumentError, /probability/)
    end
  end

  describe "closing line value" do
    it "compares the taken price with the closing price on the same selection" do
      # 2.40 taken, closed at 2.10: we beat the close.
      expect(described_class.closing_line_value(taken_odds: 2.40, closing_odds: 2.10))
        .to be_within(1e-9).of((2.40 / 2.10) - 1)
    end

    it "is negative when the price shortened against us in the other direction" do
      expect(described_class.closing_line_value(taken_odds: 1.90, closing_odds: 2.20))
        .to be < 0
    end

    it "refuses to compare across different odds values of 1 or below" do
      expect { described_class.closing_line_value(taken_odds: 1.0, closing_odds: 2.0) }
        .to raise_error(ArgumentError)
    end
  end
end
