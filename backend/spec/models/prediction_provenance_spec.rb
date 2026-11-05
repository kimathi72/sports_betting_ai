require "rails_helper"

# Issued predictions are evidence, so they must not be rewritable.
#
# The schema already allowed a prediction's `outcomes` to be overwritten after the
# fact. That would destroy the very record prospective evaluation exists to protect:
# a "prospective" prediction whose probabilities were edited after the result is
# indistinguishable from hindsight. These specs pin the guard.
RSpec.describe Prediction, "provenance and immutability" do
  let(:competition) { Competition.create!(name: "Immutable League #{SecureRandom.hex(3)}") }
  let(:season) { Season.create!(competition: competition, name: "2026/27") }
  let(:home) { Team.create!(name: "Immutable Home #{SecureRandom.hex(3)}") }
  let(:away) { Team.create!(name: "Immutable Away #{SecureRandom.hex(3)}") }
  let(:fixture) do
    Match.create!(competition: competition, season: season, home_team: home, away_team: away,
                  kickoff_at: Time.utc(2026, 11, 7, 15), status: "scheduled")
  end

  def build(outcomes: { "H" => 0.5, "D" => 0.3, "A" => 0.2 }, generated_at: Time.utc(2026, 11, 7, 9))
    Prediction.create!(match: fixture, market: "1x2", outcomes: outcomes,
                       model_version: "v2", generated_at: generated_at)
  end

  describe "timestamp capture" do
    # `generated_at` is REQUIRED (the schema is NOT NULL and the model validates
    # presence): a prediction with no issue time cannot be judged prospective or
    # hindsight, so defaulting it to "now" would silently turn an unattributable
    # row into an apparently-timely one. The original expectation of a default was
    # written against behaviour the model never had.
    it "refuses to store a prediction with no generated_at" do
      prediction = Prediction.new(match: fixture, market: "1x2",
                                  outcomes: { "H" => 0.5, "D" => 0.3, "A" => 0.2 },
                                  model_version: "v2")

      expect(prediction).not_to be_valid
      expect(prediction.errors[:generated_at]).to be_present
    end

    it "records the kickoff the match had at issue time" do
      prediction = build

      expect(prediction.issued_kickoff_at).to eq(Time.utc(2026, 11, 7, 15))
    end

    it "keeps the issued kickoff even after the match is rescheduled" do
      prediction = build
      fixture.update!(kickoff_at: Time.utc(2026, 12, 5, 15))

      expect(prediction.reload.issued_kickoff_at).to eq(Time.utc(2026, 11, 7, 15))
    end
  end

  describe "digest capture" do
    it "stores a freeze digest when the producer supplies one" do
      prediction = Prediction.create!(
        match: fixture, market: "1x2", outcomes: { "H" => 0.5, "D" => 0.3, "A" => 0.2 },
        model_version: "v2", model_freeze_digest: "deadbeef" * 4,
        generated_at: Time.utc(2026, 11, 7, 9),
      )

      expect(prediction.model_freeze_digest).to eq("deadbeef" * 4)
    end

    it "leaves the digest null when unknown rather than inventing one" do
      expect(build.model_freeze_digest).to be_nil
    end
  end

  describe "immutability" do
    it "refuses to change outcomes after issue" do
      prediction = build

      prediction.outcomes = { "H" => 0.9, "D" => 0.05, "A" => 0.05 }

      expect(prediction).not_to be_valid
      expect(prediction.errors[:outcomes]).to be_present
    end

    it "refuses to change the market after issue" do
      prediction = build
      prediction.market = "btts"

      expect(prediction).not_to be_valid
    end

    it "refuses to change generated_at after issue" do
      prediction = build
      prediction.generated_at = Time.utc(2026, 11, 7, 16)

      expect(prediction).not_to be_valid
    end

    it "refuses to move a prediction to another match" do
      prediction = build
      other = Match.create!(competition: competition, season: season, home_team: away,
                            away_team: home, kickoff_at: Time.utc(2026, 11, 8, 15),
                            status: "scheduled")

      prediction.match_id = other.id

      expect(prediction).not_to be_valid
    end

    it "still allows non-evidence attributes to change" do
      prediction = build
      prediction.superseded_at = Time.current

      expect(prediction).to be_valid
    end
  end

  describe "market probability integrity" do
    it "still requires 1X2 to sum to 1" do
      bad = Prediction.new(match: fixture, market: "1x2",
                           outcomes: { "H" => 0.5, "D" => 0.3, "A" => 0.3 },
                           model_version: "v2")
      expect(bad).not_to be_valid
    end

    it "still allows double chance to sum to 2 because the events overlap" do
      dc = Prediction.new(match: fixture, market: "double_chance",
                          outcomes: { "1x" => 0.7, "x2" => 0.5, "12" => 0.8 },
                          model_version: "v2", generated_at: Time.utc(2026, 11, 7, 9),
                          home_probability: 0, draw_probability: 0, away_probability: 1)
      expect(dc).to be_valid
    end
  end

  describe "historical records" do
    it "does not retroactively populate provenance on existing rows" do
      # A prediction created through the normal path has provenance; one written
      # with explicit NULLs (as every pre-existing row is) must stay NULL.
      legacy = Prediction.create!(match: fixture, market: "btts",
                                  outcomes: { "yes" => 0.6, "no" => 0.4 },
                                  model_version: "v1", generated_at: Time.utc(2026, 11, 7, 9),
                                  home_probability: 0, draw_probability: 0, away_probability: 1)
      legacy.update_columns(issued_kickoff_at: nil, model_freeze_digest: nil)

      legacy.reload
      expect(legacy.issued_kickoff_at).to be_nil
      expect(legacy.model_freeze_digest).to be_nil
    end
  end
end
