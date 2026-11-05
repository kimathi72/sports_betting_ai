require 'rails_helper'

# Prospective evaluation: which issued predictions may be scored against results.
#
# THE RULE
# --------
# A prediction is prospective evidence only if it was issued BEFORE the match
# kicked off, carries complete provenance, and the match has a verified final
# result. Everything else is either exploratory (issued late) or unusable (no
# result, rescheduled fixture, missing provenance).
#
# WHY THIS IS STRICTER THAN "HAS A RESULT"
# ----------------------------------------
# The schema already stores every prediction ever generated, including the ones
# made after a match finished. Scoring those against the result would produce a
# spectacular and entirely meaningless accuracy. The eligibility object exists to
# make that mistake impossible rather than merely discouraged.
RSpec.describe Predictions::ProspectiveEligibility do
  let(:competition) { Competition.create!(name: "Prospective League #{SecureRandom.hex(3)}") }
  let(:season) { Season.create!(competition: competition, name: "2026/27") }
  let(:home) { Team.create!(name: "Prospective Home #{SecureRandom.hex(3)}") }
  let(:away) { Team.create!(name: "Prospective Away #{SecureRandom.hex(3)}") }

  # Matches are created as `scheduled` and completed afterwards, because a
  # prediction may only be issued for a fixture that has not been played.
  # Always created as `scheduled`, because a prediction may only be issued before a
  # fixture is played. `complete!` moves it to its final state afterwards, which is
  # the same order the real system experiences.
  def match(kickoff: Time.utc(2026, 11, 7, 15))
    Match.create!(competition: competition, season: season, home_team: home,
                  away_team: away, kickoff_at: kickoff, status: "scheduled")
  end

  def complete!(fixture, home_score = 2, away_score = 1)
    fixture.update_columns(status: "completed", home_score: home_score, away_score: away_score)
    fixture.reload
  end

  def set_status!(fixture, status)
    fixture.update_columns(status: status)
    fixture.reload
  end

  # `skip_validations: true` builds a row that the model would normally refuse, to
  # simulate legacy or provenance-less records that already exist in the database.
  def prediction_for(fixture, generated_at:, market: "1x2",
                     model_version: "v2", feature_version: "v2", digest: "abc123",
                     outcomes: { "H" => 0.5, "D" => 0.3, "A" => 0.2 }, skip_validations: false)
    # The model refuses to predict a match that has already been played, which is
    # the correct guard. Tests therefore build the match as scheduled, issue the
    # prediction, and complete the match afterwards — the real-world order.
    record = Prediction.new(
      match: fixture.reload, market: market, outcomes: outcomes,
      home_probability: 0.5, draw_probability: 0.3, away_probability: 0.2,
      model_version: model_version,
      model_metadata: { "feature_version" => feature_version,
                        "model_freeze_digest" => digest },
      generated_at: generated_at
    )
    if skip_validations
      record.save!(validate: false)
    else
      record.save!
    end
    record
  end

  subject(:eligibility) { described_class.new }

  describe "a qualifying prediction" do
    it "is eligible when issued strictly before kickoff with full provenance" do
      fixture = match(kickoff: Time.utc(2026, 11, 7, 15))
      prediction = prediction_for(fixture, generated_at: Time.utc(2026, 11, 7, 9))
      complete!(fixture)

      verdict = eligibility.call(prediction)

      expect(verdict).to be_eligible
      expect(verdict.reason).to be_nil
    end
  end

  describe "timing" do
    it "rejects a prediction issued at exactly kickoff" do
      kickoff = Time.utc(2026, 11, 7, 15)
      fixture = match(kickoff: kickoff)
      prediction = prediction_for(fixture, generated_at: kickoff)
      complete!(fixture)

      verdict = eligibility.call(prediction)

      expect(verdict).not_to be_eligible
      expect(verdict.reason).to eq(:issued_at_or_after_kickoff)
    end

    it "rejects a prediction issued after the match finished" do
      fixture = match(kickoff: Time.utc(2026, 11, 7, 15))
      prediction = prediction_for(fixture, generated_at: Time.utc(2026, 11, 8, 10))
      complete!(fixture)

      expect(eligibility.call(prediction)).not_to be_eligible
      expect(eligibility.call(prediction).reason).to eq(:issued_at_or_after_kickoff)
    end

    it "cannot exist without an issuance timestamp: the column is NOT NULL" do
      # The database forbids a null `generated_at`, so a "prediction with no
      # timestamp" is unrepresentable rather than merely discouraged. The
      # eligibility check still handles nil defensively (an unsaved object or a
      # future schema change), which is asserted directly here.
      fixture = match
      unsaved = Prediction.new(match: fixture, market: "1x2",
                               outcomes: { "H" => 0.5, "D" => 0.3, "A" => 0.2 },
                               home_probability: 0.5, draw_probability: 0.3,
                               away_probability: 0.2, model_version: "v2")

      expect(eligibility.call(unsaved).reason).to eq(:missing_issued_at)
      expect { prediction_for(fixture, generated_at: nil, skip_validations: true) }
        .to raise_error(ActiveRecord::NotNullViolation)
    end
  end

  describe "provenance" do
    it "rejects a prediction with no model version" do
      fixture = match(kickoff: Time.utc(2026, 11, 7, 15))
      prediction = prediction_for(fixture, generated_at: Time.utc(2026, 11, 7, 9),
                                          model_version: "", skip_validations: true)
      complete!(fixture)

      expect(eligibility.call(prediction).reason).to eq(:missing_model_version)
    end

    it "rejects a prediction with no feature version" do
      fixture = match(kickoff: Time.utc(2026, 11, 7, 15))
      prediction = prediction_for(fixture, generated_at: Time.utc(2026, 11, 7, 9),
                                          feature_version: nil, skip_validations: true)
      complete!(fixture)

      expect(eligibility.call(prediction).reason).to eq(:missing_feature_version)
    end

    it "rejects a prediction with no model freeze digest" do
      fixture = match(kickoff: Time.utc(2026, 11, 7, 15))
      prediction = prediction_for(fixture, generated_at: Time.utc(2026, 11, 7, 9),
                                          digest: nil, skip_validations: true)
      complete!(fixture)

      expect(eligibility.call(prediction).reason).to eq(:missing_freeze_digest)
    end
  end

  describe "result availability" do
    it "rejects a match that has not finished" do
      fixture = match
      prediction = prediction_for(fixture, generated_at: Time.utc(2026, 11, 7, 9))

      expect(eligibility.call(prediction).reason).to eq(:match_not_completed)
    end

    it "cannot reference a completed match without scores: the database forbids it" do
      # CHECK constraint `matches_completed_has_scores` makes "completed with no
      # result" unrepresentable, so the `missing_result` branch is defensive only.
      fixture = match

      expect do
        fixture.update_columns(status: "completed", home_score: nil, away_score: nil)
      end.to raise_error(ActiveRecord::StatementInvalid)
    end

    it "refuses a match object that reports completed without a result" do
      # The defensive branch, exercised on an unpersisted match so the database
      # constraint is not involved.
      fixture = match
      prediction = prediction_for(fixture, generated_at: Time.utc(2026, 11, 7, 9))

      allow(fixture).to receive(:status).and_return("completed")
      allow(fixture).to receive(:home_score).and_return(nil)
      allow(fixture).to receive(:away_score).and_return(nil)

      expect(eligibility.call(prediction).reason).to eq(:missing_result)
    end

    it "rejects a postponed fixture" do
      fixture = match
      prediction = prediction_for(fixture, generated_at: Time.utc(2026, 11, 7, 9))
      set_status!(fixture, "postponed")

      expect(eligibility.call(prediction).reason).to eq(:match_not_completed)
    end

    it "rejects a cancelled fixture" do
      fixture = match
      prediction = prediction_for(fixture, generated_at: Time.utc(2026, 11, 7, 9))
      set_status!(fixture, "cancelled")

      expect(eligibility.call(prediction).reason).to eq(:match_not_completed)
    end
  end

  describe "rescheduling" do
    it "rejects a prediction issued before a kickoff that later moved" do
      # Issued for the original fixture, then the match was rescheduled to a later
      # date. The prediction describes a match that did not happen when predicted,
      # so it is not prospective evidence for the result it would be scored against.
      fixture = match(kickoff: Time.utc(2026, 11, 7, 15))
      prediction = prediction_for(fixture, generated_at: Time.utc(2026, 11, 7, 9))
      complete!(fixture)

      fixture.update!(kickoff_at: Time.utc(2026, 12, 5, 15))

      verdict = eligibility.call(prediction)

      expect(verdict).not_to be_eligible
      expect(verdict.reason).to eq(:kickoff_changed_since_issue)
    end
  end
end
