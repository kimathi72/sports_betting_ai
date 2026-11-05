require "rails_helper"

# Paper-bet settlement: what a would-be bet won or lost, and what it must refuse.
#
# SYNTHETIC DATA ONLY. No odds are ingested and no bet is placed. These specs pin
# the arithmetic and the refusals, which is the part that must be right before any
# real evidence exists to run through it.
RSpec.describe Odds::PaperBet do
  def bet(market:, selection:, odds:, stake: 10.0, probability: 0.5)
    described_class.new(market: market, selection: selection, decimal_odds: odds,
                        stake: stake, model_probability: probability)
  end

  describe "construction" do
    it "accepts a valid decimal price" do
      expect(bet(market: "1x2", selection: "H", odds: 2.5)).to be_valid
    end

    it "refuses odds of 1.0 or below" do
      expect(bet(market: "1x2", selection: "H", odds: 1.0)).not_to be_valid
    end

    it "refuses a zero or negative stake" do
      expect(bet(market: "1x2", selection: "H", odds: 2.5, stake: 0)).not_to be_valid
      expect(bet(market: "1x2", selection: "H", odds: 2.5, stake: -5)).not_to be_valid
    end

    it "refuses a selection that does not belong to the market" do
      expect(bet(market: "btts", selection: "H", odds: 2.5)).not_to be_valid
    end

    it "refuses correct score, which cannot be priced as a market" do
      expect(bet(market: "correct_score", selection: "2-1", odds: 8.0)).not_to be_valid
    end
  end

  describe "settlement" do
    it "pays profit on a winning selection" do
      settled = bet(market: "1x2", selection: "H", odds: 2.5, stake: 10).settle(actual_outcome: "H")

      expect(settled).to be_won
      expect(settled.profit).to be_within(1e-9).of(15.0)
      expect(settled.returned).to be_within(1e-9).of(25.0)
    end

    it "loses the stake on a losing selection" do
      settled = bet(market: "1x2", selection: "H", odds: 2.5, stake: 10).settle(actual_outcome: "A")

      expect(settled).to be_lost
      expect(settled.profit).to be_within(1e-9).of(-10.0)
      expect(settled.returned).to be_within(1e-9).of(0.0)
    end

    it "settles a draw correctly for a draw selection" do
      settled = bet(market: "1x2", selection: "D", odds: 3.4, stake: 10).settle(actual_outcome: "D")

      expect(settled.profit).to be_within(1e-9).of(24.0)
    end

    it "settles over/under from the scoreline" do
      over = bet(market: "over_under_2.5", selection: "over", odds: 1.9, stake: 10)
      under = bet(market: "over_under_2.5", selection: "under", odds: 1.9, stake: 10)

      expect(over.settle(actual_outcome: "over")).to be_won
      expect(under.settle(actual_outcome: "over")).to be_lost
    end

    it "settles BTTS from the scoreline" do
      yes = bet(market: "btts", selection: "yes", odds: 1.8, stake: 10)

      expect(yes.settle(actual_outcome: "yes")).to be_won
      expect(yes.settle(actual_outcome: "no")).to be_lost
    end

    it "settles a double chance selection that wins on a draw" do
      # 1X wins on a home win OR a draw. This is the case a naive "one selection
      # wins" model gets wrong.
      one_x = bet(market: "double_chance", selection: "1x", odds: 1.3, stake: 10)

      expect(one_x.settle(actual_outcome: "D")).to be_won
      expect(one_x.settle(actual_outcome: "H")).to be_won
      expect(one_x.settle(actual_outcome: "A")).to be_lost
    end

    it "refuses to settle against an outcome the market does not have" do
      expect { bet(market: "1x2", selection: "H", odds: 2.5).settle(actual_outcome: "yes") }.to raise_error(Odds::PaperBet::InvalidOutcome)
    end

    it "refuses to settle twice" do
      settled = bet(market: "1x2", selection: "H", odds: 2.5).settle(actual_outcome: "H")

      expect { settled.settle(actual_outcome: "A") }.to raise_error(Odds::PaperBet::AlreadySettled)
    end
  end

  describe "expected value at placement" do
    # EV is reported in CURRENCY for the stake, not per unit: a 10-unit stake at
    # 0.45 on a 2.5 price is worth 0.45*2.5*10 - 10 = +1.25. Reporting per-unit EV
    # beside a currency profit would make the two columns incomparable.
    it "is computed from the model probability, the taken price and the stake" do
      expect(bet(market: "1x2", selection: "H", odds: 2.5, probability: 0.45).expected_value).to be_within(1e-9).of(1.25)
    end

    it "is negative when the model is behind the price" do
      expect(bet(market: "1x2", selection: "H", odds: 2.5, probability: 0.30).expected_value).to be_within(1e-9).of(-2.5)
    end

    it "is nil when no model probability was supplied" do
      expect(bet(market: "1x2", selection: "H", odds: 2.5, probability: nil).expected_value).to be_nil
    end
  end

  describe "closing line value" do
    it "is recorded when a closing price is supplied" do
      settled = bet(market: "1x2", selection: "H", odds: 2.5)
        .settle(actual_outcome: "H", closing_odds: 2.2)

      expect(settled.closing_line_value).to be_within(1e-9).of((2.5 / 2.2) - 1)
    end

    it "is nil when no closing price was captured" do
      expect(bet(market: "1x2", selection: "H", odds: 2.5).settle(actual_outcome: "H").closing_line_value).to be_nil
    end
  end

  describe "portfolio summary" do
    it "reports staked, returned, profit and ROI over settled bets" do
      bets = [
        bet(market: "1x2", selection: "H", odds: 2.0, stake: 10).settle(actual_outcome: "H"),
        bet(market: "1x2", selection: "H", odds: 2.0, stake: 10).settle(actual_outcome: "A"),
        bet(market: "1x2", selection: "H", odds: 2.0, stake: 10).settle(actual_outcome: "H"),
      ]

      summary = described_class.summarise(bets)

      expect(summary[:bets]).to eq(3)
      expect(summary[:staked]).to be_within(1e-9).of(30.0)
      expect(summary[:returned]).to be_within(1e-9).of(40.0)
      expect(summary[:profit]).to be_within(1e-9).of(10.0)
      expect(summary[:roi]).to be_within(1e-9).of(10.0 / 30.0)
    end

    it "ignores unsettled bets in the totals" do
      bets = [
        bet(market: "1x2", selection: "H", odds: 2.0, stake: 10).settle(actual_outcome: "H"),
        bet(market: "1x2", selection: "H", odds: 2.0, stake: 10),
      ]

      summary = described_class.summarise(bets)

      expect(summary[:bets]).to eq(1)
      expect(summary[:staked]).to be_within(1e-9).of(10.0)
    end

    it "reports zero ROI rather than dividing by zero when nothing is settled" do
      expect(described_class.summarise([])[:roi]).to eq(0.0)
    end
  end
end
