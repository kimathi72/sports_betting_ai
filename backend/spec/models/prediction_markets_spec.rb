require "rails_helper"

# Predictions are per MARKET, not per match.
#
# The original schema stored exactly one probability triple per match, so a
# second market had nowhere to go: writing over/under into the home/draw/away
# columns would corrupt the 1X2 prediction. These specs pin the market-aware
# contract, including the backwards-compatible 1X2 behaviour that existing
# endpoints rely on.
RSpec.describe Prediction, "markets" do
  let(:competition) { Competition.create!(name: "Premier League", code: "EPL") }
  let(:season) { Season.create!(competition: competition, name: "2026/27") }
  let(:home) { Team.create!(name: "Arsenal") }
  let(:away) { Team.create!(name: "Chelsea") }

  let(:fixture_match) do
    Match.create!(competition: competition, season: season, home_team: home, away_team: away,
                  kickoff_at: Time.utc(2026, 8, 20, 15, 0), status: "scheduled")
  end

  def build_1x2(overrides = {})
    Prediction.new(
      {
        match: fixture_match, market: "1x2", model_version: "v1",
        home_probability: 0.5, draw_probability: 0.3, away_probability: 0.2,
        generated_at: Time.utc(2026, 8, 19, 10, 0),
      }.merge(overrides)
    )
  end

  def build_market(market, outcomes, version: "v1", generated_at: Time.utc(2026, 8, 19, 10, 0))
    Prediction.new(
      match: fixture_match, market: market, model_version: version,
      home_probability: 0, draw_probability: 0, away_probability: 1,
      outcomes: outcomes, generated_at: generated_at,
    )
  end

  describe "the supported markets" do
    it "declares exactly the markets the ML service produces" do
      expect(Prediction::MARKETS).to contain_exactly(
        "1x2", "double_chance", "over_under_2.5", "btts", "correct_score"
      )
    end

    it "classifies the derived markets apart from the fitted ones" do
      # Both are projections: double chance of the 1X2 sums, correct score of the
      # joint scoreline grid. Neither may ever have an artifact of its own.
      expect(Prediction::DERIVED_MARKETS).to contain_exactly("double_chance", "correct_score")
    end

    it "defaults to 1x2 so existing rows keep their meaning" do
      expect(Prediction.new.market).to eq("1x2")
    end
  end

  describe "coexistence" do
    it "allows several markets for one match at the same time" do
      build_1x2.save!
      build_market("btts", { "yes" => 0.6, "no" => 0.4 }).save!

      expect(Prediction.where(match_id: fixture_match.id).count).to eq(2)
    end

    it "does not supersede a different market" do
      build_1x2.save!
      btts = build_market("btts", { "yes" => 0.6, "no" => 0.4 })
      btts.save!

      expect(Prediction.find_by(market: "1x2")).not_to be_superseded
      expect(btts.reload).not_to be_superseded
    end

    it "supersedes only the previous prediction of the SAME market" do
      first = build_1x2
      first.save!
      btts = build_market("btts", { "yes" => 0.6, "no" => 0.4 })
      btts.save!

      newer = build_1x2(home_probability: 0.4, draw_probability: 0.4, away_probability: 0.2,
                        generated_at: Time.utc(2026, 8, 19, 12, 0))
      newer.save!

      expect(first.reload).to be_superseded
      expect(newer.reload).not_to be_superseded
      expect(btts.reload).not_to be_superseded
    end

    it "refuses two CURRENT predictions for the same market, enforced by the database" do
      build_1x2.save!

      # Bypass the model's superseding to prove the unique partial index holds.
      expect {
        Prediction.insert_all!([{
          match_id: fixture_match.id, market: "1x2", model_version: "v1",
          home_probability: 0.2, draw_probability: 0.3, away_probability: 0.5,
          generated_at: Time.current, created_at: Time.current, updated_at: Time.current,
          features: {}, model_metadata: {}, outcomes: {},
        }])
      }.to raise_error(ActiveRecord::StatementInvalid, /index_predictions_current_per_market|duplicate key/)
    end
  end

  describe "market validation" do
    it "rejects an unsupported market" do
      expect(build_market("teleportation", { "a" => 1.0 })).not_to be_valid
    end

    it "is enforced by a database check constraint" do
      # The check constraint is widened together with Prediction::MARKETS — it is
      # never dropped — so an unknown market must still be refused by the database,
      # not only by the Rails validation.
      build_1x2.save!

      expect {
        ActiveRecord::Base.connection.execute(
          "UPDATE predictions SET market = 'teleportation' WHERE id = #{Prediction.last.id}"
        )
      }.to raise_error(ActiveRecord::StatementInvalid, /predictions_market_supported/)
    end

    it "accepts the correct_score market the constraint was widened for" do
      build_1x2.save!
      expect {
        ActiveRecord::Base.connection.execute(
          "UPDATE predictions SET market = 'correct_score' WHERE id = #{Prediction.last.id}"
        )
      }.not_to raise_error
    end
  end

  describe "over/under 2.5 outcomes" do
    it "accepts over and under that sum to one" do
      record = build_market("over_under_2.5", { "over" => 0.55, "under" => 0.45 })

      expect(record).to be_valid
    end

    it "rejects outcomes that do not sum to one" do
      record = build_market("over_under_2.5", { "over" => 0.55, "under" => 0.55 })

      expect(record).not_to be_valid
      expect(record.errors.full_messages.join(" ")).to match(/sum/i)
    end

    it "rejects a missing outcome key" do
      record = build_market("over_under_2.5", { "over" => 1.0 })

      expect(record).not_to be_valid
    end

    it "rejects a probability outside 0..1" do
      record = build_market("over_under_2.5", { "over" => 1.2, "under" => -0.2 })

      expect(record).not_to be_valid
    end
  end

  describe "btts outcomes" do
    it "accepts yes/no that sum to one" do
      expect(build_market("btts", { "yes" => 0.6, "no" => 0.4 })).to be_valid
    end

    it "rejects an unknown outcome key" do
      expect(build_market("btts", { "true" => 0.6, "false" => 0.4 })).not_to be_valid
    end
  end

  describe "double chance derived from 1X2" do
    it "exposes 1X, X2 and 12 computed from the stored 1X2 probabilities" do
      record = build_1x2(home_probability: 0.5, draw_probability: 0.3, away_probability: 0.2)
      record.save!

      expect(record.double_chance).to eq(
        "1x" => 0.8, "x2" => 0.5, "12" => 0.7,
      )
    end

    it "stores double chance outcomes that match the 1X2 derivation" do
      # Double chance outcomes OVERLAP: 1X and X2 both contain the draw, so they
      # sum to 2, not 1. The meaningful identity is that each pair is consistent
      # with the same underlying 1X2 distribution.
      record = build_market("double_chance", { "1x" => 0.8, "x2" => 0.5, "12" => 0.7 })
      record.save!

      # 1x + x2 - 12 == 2 * P(D), and 1x + x2 + 12 == 2
      expect(record.outcomes["1x"] + record.outcomes["x2"] + record.outcomes["12"]).to be_within(1e-6).of(2.0)
      expect(record.outcomes["1x"] + record.outcomes["x2"] - record.outcomes["12"]).to be_within(1e-6).of(0.6)
    end

    it "rejects double chance that contradicts the stored 1X2 for the same match" do
      build_1x2(home_probability: 0.5, draw_probability: 0.3, away_probability: 0.2).save!

      wrong = build_market("double_chance", { "1x" => 0.5, "x2" => 0.5, "12" => 0.5 })

      expect(wrong).not_to be_valid
      expect(wrong.errors.full_messages.join(" ")).to match(/double chance|1x2/i)
    end
  end

  describe "double chance casing from the ML service" do
    it "accepts the ML service's upper-case 1X/X2 keys and stores canonical lower-case" do
      # ml/app/features.py emits "1X"/"X2"; Rails stores "1x"/"x2" so the API has
      # one canonical form regardless of which producer wrote the row.
      record = build_market("double_chance", { "1X" => 0.8, "X2" => 0.5, "12" => 0.7 })

      expect(record).to be_valid
      record.save!
      expect(record.market_outcomes.keys).to contain_exactly("1x", "x2", "12")
    end

    it "does not down-case the 1X2 outcome keys" do
      record = build_1x2
      record.save!

      expect(record.market_outcomes.keys).to contain_exactly("H", "D", "A")
      expect(record.selection).to eq("H")
    end
  end

  describe "the headline outcome of a non-1X2 market" do
    # DEFECT FOUND BY END-TO-END TESTING: a correct-score row reported
    # most_likely_outcome "away" with 1.0/0.0/0.0, because the accessor read the
    # legacy 1X2 columns that every non-1X2 market leaves at that neutral value.
    # The API serves this field, so the app displayed a confident "away" for a market
    # that is about scorelines, not results.
    it "is nil for a market that has no home/draw/away outcomes" do
      record = build_market("correct_score", { "2-1" => 0.12, "1-1" => 0.11 })
      record.save!
      expect(record.reload.most_likely_outcome).to be_nil
    end

    it "is nil for over/under and BTTS, which are not three-way outcomes either" do
      over_under = build_market("over_under_2.5", { "over" => 0.55, "under" => 0.45 })
      over_under.save!
      expect(over_under.reload.most_likely_outcome).to be_nil
    end

    it "still reports the favourite for 1X2" do
      expect(build_1x2.most_likely_outcome).to eq("home")
    end
  end

  describe "backwards compatibility" do
    it "keeps the legacy home/draw/away accessors working for 1x2" do
      record = build_1x2
      record.save!

      expect(record.reload.probabilities).to eq("home" => 0.5, "draw" => 0.3, "away" => 0.2)
      expect(record.most_likely_outcome).to eq("home")
    end

    it "still requires a 1X2 distribution to sum to one" do
      expect(build_1x2(home_probability: 0.9, draw_probability: 0.9)).not_to be_valid
    end
  end
end
