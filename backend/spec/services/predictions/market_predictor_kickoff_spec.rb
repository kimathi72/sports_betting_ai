require "rails_helper"

# Regression test for the two predictions the sweep had to REFUSE on 2026-11-04.
#
# WHAT HAPPENED
# -------------
# The first live pipeline sweep (11 competitions x 5 markets) requested a
# prediction for the first `scheduled` fixture in each competition's current
# season. Two of those fixtures (39662 in E0, 39676 in E1) had actually already
# kicked off: their results had never been ingested, so the database still called
# them scheduled. The predictions were therefore issued AFTER the match — the
# request carried no kickoff and nothing checked the clock against it.
#
# The evidence gate caught them (`issued_at_or_after_kickoff`), so no hindsight was
# ever counted as prospective evidence. The gate is the safety net; the producer
# should not have created those rows in the first place, because
# `Predictions::MarketPredictor` refuses a COMPLETED match but says nothing about a
# scheduled fixture whose kickoff has passed. That stale-status window is the hole.
RSpec.describe Predictions::MarketPredictor, "kickoff already passed" do
  let(:competition) { Competition.create!(name: "Stale Status League #{SecureRandom.hex(3)}") }
  let(:season) { Season.create!(competition: competition, name: "2026/27") }
  let(:home) { Team.create!(name: "Stale Home #{SecureRandom.hex(3)}") }
  let(:away) { Team.create!(name: "Stale Away #{SecureRandom.hex(3)}") }

  def fixture(kickoff:, status: "scheduled")
    Match.create!(competition: competition, season: season, home_team: home, away_team: away,
                  kickoff_at: kickoff, status: status,
                  home_score: status == "completed" ? 1 : nil,
                  away_score: status == "completed" ? 0 : nil)
  end

  let(:predictor) { described_class.new(service_url: "http://ml.invalid:8000") }

  it "refuses a scheduled fixture whose kickoff is in the past" do
    match = fixture(kickoff: 2.hours.ago)

    result = predictor.call(match, market: "1x2")

    expect(result).to be_failure
    expect(result.message).to match(/kicked off/i)
    expect(result.transient?).to be(false)
  end

  it "still refuses a completed fixture" do
    match = fixture(kickoff: 1.day.ago, status: "completed")

    result = predictor.call(match, market: "1x2")

    expect(result).to be_failure
    expect(Prediction.where(match_id: match.id).count).to eq(0)
  end

  # The refusal must depend on the clock, not on the stored status, so a fixture
  # that is still marked scheduled but has started is not treated as predictable.
  it "does not create any prediction row when it refuses" do
    match = fixture(kickoff: 1.minute.ago)

    predictor.call(match, market: "1x2")

    expect(Prediction.count).to eq(0)
  end
end
