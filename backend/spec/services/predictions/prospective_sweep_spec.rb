require "rails_helper"

# The sweep scores what is ready and reports what is not.
#
# It exists so prospective evidence accumulates on its own, but it must not become
# a way to manufacture evidence: it never creates a prediction, never scores a
# match that has not completed, and never retries a row the gate has refused.
RSpec.describe Predictions::ProspectiveSweep do
  let(:competition) { Competition.create!(name: "Sweep League #{SecureRandom.hex(3)}") }
  let(:season) { Season.create!(competition: competition, name: "2026/27") }
  let(:home) { Team.create!(name: "Sweep Home #{SecureRandom.hex(3)}") }
  let(:away) { Team.create!(name: "Sweep Away #{SecureRandom.hex(3)}") }

  def fixture(status: "scheduled", kickoff: Time.utc(2026, 11, 7, 15), hs: nil, as: nil)
    Match.create!(competition: competition, season: season, home_team: home, away_team: away,
                  kickoff_at: kickoff, status: status, home_score: hs, away_score: as)
  end

  # Issue while scheduled, then complete — the real ordering.
  def issue(match, generated_at: Time.utc(2026, 11, 7, 9), digest: "a" * 64)
    Prediction.create!(
      match: match, market: "1x2",
      outcomes: { "H" => 0.5, "D" => 0.3, "A" => 0.2 },
      home_probability: 0.5, draw_probability: 0.3, away_probability: 0.2,
      model_version: "v2", model_freeze_digest: digest,
      model_metadata: { "feature_version" => "v2" },
      generated_at: generated_at
    )
  end

  def complete(match, hs, as)
    match.update_columns(status: "completed", home_score: hs, away_score: as)
  end

  it "does not write in preview mode" do
    match = fixture
    issue(match)
    complete(match, 2, 1)

    report = described_class.new.call

    expect(report.evaluated.size).to eq(1)
    expect(ProspectiveEvaluationRecord.count).to eq(0)
  end

  it "records the outcome when applied" do
    match = fixture
    prediction = issue(match)
    complete(match, 2, 1)

    report = described_class.new.call(apply: true)

    expect(report.evaluated.size).to eq(1)
    record = ProspectiveEvaluationRecord.find_by(prediction_id: prediction.id)
    expect(record.actual_outcome).to eq("H")
    expect(record.was_correct).to be(true)
    expect(record.home_score).to eq(2)
  end

  it "leaves predictions whose match has not finished as pending" do
    match = fixture
    issue(match)

    report = described_class.new.call(apply: true)

    expect(report.pending).to eq(1)
    expect(report.evaluated).to be_empty
    expect(ProspectiveEvaluationRecord.count).to eq(0)
  end

  it "scores a prediction only once even if run twice" do
    match = fixture
    issue(match)
    complete(match, 0, 0)

    described_class.new.call(apply: true)
    report = described_class.new.call(apply: true)

    expect(ProspectiveEvaluationRecord.count).to eq(1)
    expect(report.evaluated).to be_empty
  end

  it "reports a prediction issued after kickoff instead of scoring it" do
    match = fixture
    issue(match, generated_at: Time.utc(2026, 11, 8, 9))
    complete(match, 2, 1)

    report = described_class.new.call(apply: true)

    expect(report.evaluated).to be_empty
    expect(report.refused.map { |r| r[:reason] }).to include(:issued_at_or_after_kickoff)
    expect(ProspectiveEvaluationRecord.count).to eq(0)
  end

  it "reports a prediction with no freeze digest instead of scoring it" do
    match = fixture
    issue(match, digest: nil)
    complete(match, 2, 1)

    report = described_class.new.call(apply: true)

    expect(report.refused.map { |r| r[:reason] }).to include(:missing_freeze_digest)
    expect(ProspectiveEvaluationRecord.count).to eq(0)
  end

  it "never creates a prediction for an already completed match" do
    match = fixture(status: "completed", hs: 3, as: 0)

    report = described_class.new.call(apply: true)

    expect(Prediction.count).to eq(0)
    expect(report.evaluated).to be_empty
  end

  it "ignores superseded predictions" do
    match = fixture
    old = issue(match)
    complete(match, 1, 0)
    # A later issue supersedes `old`; only the live row is evidence.
    newer = Prediction.new(match: match, market: "1x2",
                           outcomes: { "H" => 0.6, "D" => 0.2, "A" => 0.2 },
                           home_probability: 0.6, draw_probability: 0.2, away_probability: 0.2,
                           model_version: "v2", model_freeze_digest: "b" * 64,
                           model_metadata: { "feature_version" => "v2" },
                           generated_at: Time.utc(2026, 11, 7, 10))
    newer.save!(validate: false) # the match is complete; the model guard is not the subject here

    described_class.new.call(apply: true)

    expect(ProspectiveEvaluationRecord.pluck(:prediction_id)).to eq([newer.id])
    expect(old.reload.superseded_at).to be_present
  end
end
