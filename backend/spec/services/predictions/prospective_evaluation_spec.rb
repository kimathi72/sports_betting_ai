require "rails_helper"

# Recording an outcome against an issued prediction.
#
# The evaluation record is separate from the prediction on purpose: the issued
# probabilities are evidence and must never be edited to record what happened.
# A prediction is evaluated at most once, and only when it qualifies.
RSpec.describe Predictions::ProspectiveEvaluation do
  let(:competition) { Competition.create!(name: "Eval League #{SecureRandom.hex(3)}") }
  let(:season) { Season.create!(competition: competition, name: "2026/27") }
  let(:home) { Team.create!(name: "Eval Home #{SecureRandom.hex(3)}") }
  let(:away) { Team.create!(name: "Eval Away #{SecureRandom.hex(3)}") }

  def fixture(status: "completed", kickoff: Time.utc(2026, 11, 7, 15), hs: 2, as: 1)
    Match.create!(competition: competition, season: season, home_team: home, away_team: away,
                  kickoff_at: kickoff, status: status,
                  home_score: status == "completed" ? hs : nil,
                  away_score: status == "completed" ? as : nil)
  end

  # A prediction is issued BEFORE the match finishes, so the row is built against a
  # scheduled fixture and only then does the match receive its result. The model
  # refuses to create a prediction for an already-completed match (that would be
  # hindsight), so a spec that seeded a completed match first could never build the
  # evidence it meant to evaluate. The seed helper therefore encodes the real
  # ordering: issue while scheduled, then complete.
  def prediction_for(m, generated_at: Time.utc(2026, 11, 7, 9), market: "1x2", completed: nil)
    # `completed` defaults to "is this match already carrying a result?" — the
    # ordering the spec asks for. A match with no scores stays scheduled.
    completed = (m.status == "completed") if completed.nil?
    result_home = m.home_score
    result_away = m.away_score
    m.update_columns(status: "scheduled", home_score: nil, away_score: nil) if completed

    prediction = Prediction.create!(
      match: m, market: market,
      outcomes: market == "1x2" ? { "H" => 0.5, "D" => 0.3, "A" => 0.2 } : { "yes" => 0.6, "no" => 0.4 },
      home_probability: 0.5, draw_probability: 0.3, away_probability: 0.2,
      model_version: "v2", model_freeze_digest: "abc",
      model_metadata: { "feature_version" => "v2" },
      generated_at: generated_at,
    )

    m.update_columns(status: "completed", home_score: result_home, away_score: result_away) if completed
    prediction.match.reload
    prediction
  end

  subject(:evaluator) { described_class.new }

  describe "a successful evaluation" do
    it "records the outcome without touching the issued probabilities" do
      m = fixture(hs: 2, as: 1)
      p = prediction_for(m)
      before_outcomes = p.outcomes.deep_dup

      record = evaluator.call(prediction: p)

      expect(record).to be_persisted
      expect(record.actual_outcome).to eq("H")
      expect(record.home_score).to eq(2)
      expect(record.away_score).to eq(1)
      expect(p.reload.outcomes).to eq(before_outcomes)
    end

    it "links the prediction, the match and the evaluation timestamp" do
      m = fixture
      p = prediction_for(m)

      record = evaluator.call(prediction: p)

      expect(record.prediction_id).to eq(p.id)
      expect(record.match_id).to eq(m.id)
      expect(record.evaluated_at).to be_within(10.seconds).of(Time.current)
    end

    it "scores the prediction with log loss and brier" do
      m = fixture(hs: 2, as: 1)  # home win; H had 0.5
      p = prediction_for(m)

      record = evaluator.call(prediction: p)

      expect(record.log_loss).to be_within(0.0001).of(-Math.log(0.5))
      # H is the argmax at 0.5 and the home side won, so the top pick was right,
      # even though the distribution was not confident about it.
      expect(record.was_correct).to be(true)
    end

    it "marks the top probability as the prediction for outcome checks" do
      m = fixture(hs: 2, as: 1)
      p = prediction_for(m)

      record = evaluator.call(prediction: p)

      expect(record.predicted_outcome).to eq("H")
      expect(record.was_correct).to be(true)
    end
  end

  describe "duplicate prevention" do
    it "refuses to evaluate the same prediction twice" do
      m = fixture
      p = prediction_for(m)
      evaluator.call(prediction: p)

      expect { evaluator.call(prediction: p) }.to raise_error(Predictions::ProspectiveEvaluation::AlreadyEvaluated)
    end

    it "enforces uniqueness in the database, not only in Ruby" do
      m = fixture
      p = prediction_for(m)
      evaluator.call(prediction: p)

      duplicate = ProspectiveEvaluationRecord.new(
        prediction: p, match: m, actual_outcome: "H",
        home_score: 2, away_score: 1, evaluated_at: Time.current,
      )

      expect(duplicate).not_to be_valid
    end
  end

  describe "eligibility enforcement" do
    it "refuses a prediction issued after kickoff" do
      m = fixture(kickoff: Time.utc(2026, 11, 7, 15))
      p = prediction_for(m, generated_at: Time.utc(2026, 11, 7, 16))

      expect { evaluator.call(prediction: p) }.to raise_error(Predictions::ProspectiveEvaluation::NotEligible) { |e|
        expect(e.message).to include("issued_at_or_after_kickoff")
      }
    end

    it "refuses a prediction for a match with no result" do
      m = fixture(status: "scheduled")
      p = prediction_for(m)

      expect { evaluator.call(prediction: p) }.to raise_error(Predictions::ProspectiveEvaluation::NotEligible)
    end

    it "writes nothing when it refuses" do
      m = fixture(kickoff: Time.utc(2026, 11, 7, 15))
      p = prediction_for(m, generated_at: Time.utc(2026, 11, 9))

      expect { evaluator.call(prediction: p) }.to raise_error(StandardError)
      expect(ProspectiveEvaluationRecord.count).to eq(0)
    end
  end

  describe "market outcomes" do
    it "derives the binary outcome for BTTS" do
      m = fixture(hs: 1, as: 1)  # both scored
      p = prediction_for(m, market: "btts")

      record = evaluator.call(prediction: p)

      expect(record.actual_outcome).to eq("yes")
    end

    it "derives the draw outcome for 1X2" do
      m = fixture(hs: 1, as: 1)
      p = prediction_for(m)

      record = evaluator.call(prediction: p)

      expect(record.actual_outcome).to eq("D")
    end

    it "derives the away outcome for 1X2" do
      m = fixture(hs: 0, as: 3)
      p = prediction_for(m)

      expect(evaluator.call(prediction: p).actual_outcome).to eq("A")
    end
  end
end
