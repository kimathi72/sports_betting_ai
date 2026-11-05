require "rails_helper"

# Regression test for the HTTP 500 on POST /api/v1/predictions.
#
# WHAT HAPPENED (2026-11-04)
# --------------------------
# Five of eleven competitions returned 500 on the 1X2 market:
#
#   PG::CheckViolation: new row for relation "predictions" violates check
#   constraint "predictions_probabilities_sum_to_one"
#   DETAIL: ... 0.40935, 0.27130, 0.31936 ... (sum 1.00001)
#
# The three legacy columns are `numeric(6,5)` and the ML service rounds each
# probability to five decimals INDEPENDENTLY. The sum of three independently
# rounded values is not always exactly the rounded sum: 0.409353..., 0.271295...,
# 0.319353... are a genuine distribution (sum 1.0 in the model), but their five
# decimal representations sum to 1.00001. The check constraint demanded an exact
# 1, so the write failed for the whole market.
#
# The constraint was asking the schema to enforce something the storage format
# cannot represent. It is not a model bug and must not be "fixed" by nudging a
# probability to make the arithmetic look nice: that would silently edit the
# model's output.
#
# WHY THE OTHER THREE CONSTRAINTS STAY
# ------------------------------------
# Non-negativity, at-most-one and the Double Chance agreement check are all
# representable facts and remain exact. Only the SUM is a rounding artefact.
RSpec.describe Prediction, "five-decimal 1X2 probabilities" do
  let(:competition) { Competition.create!(name: "Serie A", code: "I1") }
  let(:season) { Season.create!(competition: competition, name: "2026/27") }
  let(:home) { Team.create!(name: "Venezia") }
  let(:away) { Team.create!(name: "Udinese") }
  let(:match) do
    Match.create!(competition: competition, season: season, home_team: home, away_team: away,
                  kickoff_at: Time.utc(2026, 11, 6, 19, 45), status: "scheduled")
  end

  # The exact triple that failed in production, in order H, D, A.
  let(:rounding_triple) { %w[0.40935 0.27130 0.31936] }

  def build(h, d, a, market: "1x2")
    Prediction.new(
      match: match, market: market, model_version: "goal-dc-v2-test",
      home_probability: h, draw_probability: d, away_probability: a,
      outcomes: { "H" => h.to_f, "D" => d.to_f, "A" => a.to_f },
      generated_at: Time.utc(2026, 11, 4, 6, 0)
    )
  end

  it "the triple really does sum to 1.00001" do
    h, d, a = rounding_triple.map { |v| BigDecimal(v) }

    expect(h + d + a).to eq(BigDecimal("1.00001"))
  end

  it "is stored rather than rejected as a check violation" do
    record = build(*rounding_triple)

    expect { record.save! }.not_to raise_error
    expect(record.reload.home_probability).to eq(BigDecimal("0.40935"))
  end

  it "preserves the model's probabilities exactly, without renormalising them" do
    record = build(*rounding_triple)
    record.save!

    expect(record.reload.outcomes).to eq("H" => 0.40935, "D" => 0.2713, "A" => 0.31936)
  end

  it "still stores a distribution that sums to exactly 1" do
    record = build("0.5", "0.3", "0.2")

    expect { record.save! }.not_to raise_error
  end

  describe "the constraints that must remain exact" do
    it "rejects a negative probability" do
      expect { build("-0.1", "0.6", "0.5").save!(validate: false) }
        .to raise_error(ActiveRecord::StatementInvalid)
    end

    it "rejects a probability above 1" do
      expect { build("1.1", "-0.1", "0").save!(validate: false) }
        .to raise_error(ActiveRecord::StatementInvalid)
    end

    # A distribution that is wrong by a visible amount must still be refused. The
    # tolerance is one unit in the last stored digit (0.00002 over three values),
    # not "close enough".
    it "rejects a sum that is off by more than rounding can explain" do
      expect { build("0.5", "0.3", "0.21").save!(validate: false) }
        .to raise_error(ActiveRecord::StatementInvalid, /sum_to_one/)
    end
  end
end
