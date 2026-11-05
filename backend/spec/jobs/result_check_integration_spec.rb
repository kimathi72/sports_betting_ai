require "rails_helper"

# Dispatcher -> individual job -> synchronizer, end to end, with a fake provider.
#
# WHY THIS EXISTS SEPARATELY
# --------------------------
# The dispatcher spec proves WHICH matches are enqueued; the job spec proves what
# one check does. Neither proves the two fit together — that the dispatcher's
# eligibility and the job's recheck agree, and that a dispatched match ends up
# with exactly the result the provider reported and nothing else changed.
RSpec.describe "result check pipeline" do
  let(:competition) { Competition.create!(name: "Pipeline #{SecureRandom.hex(3)}", code: "E0") }
  let(:season) { Season.create!(competition: competition, name: "2026/27") }
  let(:home) { Team.create!(name: "Pipe Home #{SecureRandom.hex(3)}") }
  let(:away) { Team.create!(name: "Pipe Away #{SecureRandom.hex(3)}") }
  let(:client) { instance_double(Import::EspnClient) }

  def fixture(kickoff:, event_id:, status: "scheduled", scores: {})
    match = Match.create!(competition: competition, season: season, home_team: home,
                          away_team: away, kickoff_at: kickoff, status: status, **scores)
    %w[ph pa].each_with_index do |external_id, index|
      identifier = ExternalIdentifier.find_or_initialize_by(provider: "espn", external_id: external_id)
      identifier.team = index.zero? ? home : away
      identifier.review_state = "approved"
      identifier.save!
    end
    ExternalIdentifier.find_or_create_by!(provider: "espn", external_id: event_id) do |identifier|
      identifier.match = match
    end
    match
  end

  def event(status_name:, state: "post", home_score: nil, away_score: nil, id:)
    {
      "id" => id,
      "date" => 3.hours.ago.utc.iso8601,
      "season" => { "year" => 2026 },
      "competitions" => [
        { "status" => { "type" => { "name" => status_name, "state" => state,
                                    "completed" => state == "post" } },
          "competitors" => [
            { "homeAway" => "home", "team" => { "id" => "ph", "displayName" => home.name },
              "score" => home_score&.to_s },
            { "homeAway" => "away", "team" => { "id" => "pa", "displayName" => away.name },
              "score" => away_score&.to_s }
          ] }
      ]
    }
  end

  before { ActiveJob::Base.queue_adapter = :test }

  it "updates only the intended match with a final result" do
    target = fixture(kickoff: 3.hours.ago, event_id: "i1001")
    bystander = fixture(kickoff: 3.hours.ago, event_id: "i1002")
    allow(client).to receive(:event).and_return(
      event(status_name: "STATUS_FULL_TIME", home_score: 2, away_score: 1, id: "i1001")
    )

    MatchResultDispatchJob.new.perform
    MatchResultCheckJob.new(client: client).perform(target.id, 1)

    expect(target.reload.status).to eq("completed")
    expect([target.home_score, target.away_score]).to eq([2, 1])
    expect(bystander.reload.status).to eq("scheduled")
    expect(bystander.home_score).to be_nil
  end

  it "leaves an in-progress match unchanged" do
    target = fixture(kickoff: 3.hours.ago, event_id: "i1003")
    allow(client).to receive(:event).and_return(
      event(status_name: "STATUS_IN_PROGRESS", state: "in", id: "i1003")
    )

    MatchResultCheckJob.new(client: client).perform(target.id, 1)

    expect(target.reload.status).to eq("in_progress")
    expect(target.home_score).to be_nil
  end

  it "does not mark a postponed match completed" do
    target = fixture(kickoff: 3.hours.ago, event_id: "i1004")
    allow(client).to receive(:event).and_return(
      event(status_name: "STATUS_POSTPONED", state: "post", id: "i1004")
    )

    MatchResultCheckJob.new(client: client).perform(target.id, 1)

    expect(target.reload.status).to eq("postponed")
    expect(target.home_score).to be_nil
  end

  it "leaves a trusted result untouched" do
    target = fixture(kickoff: 3.hours.ago, event_id: "i1005", status: "completed",
                     scores: { home_score: 1, away_score: 1 })
    allow(client).to receive(:event).and_return(
      event(status_name: "STATUS_FULL_TIME", home_score: 4, away_score: 0, id: "i1005")
    )

    MatchResultCheckJob.new(client: client).perform(target.id, 1)

    expect([target.reload.home_score, target.away_score]).to eq([1, 1])
  end

  it "rejects a payload whose clubs do not match the fixture" do
    target = fixture(kickoff: 3.hours.ago, event_id: "i1006")
    payload = event(status_name: "STATUS_FULL_TIME", home_score: 3, away_score: 0, id: "i1006")
    payload["competitions"][0]["competitors"][0]["team"]["id"] = "pa"
    payload["competitions"][0]["competitors"][1]["team"]["id"] = "ph"
    allow(client).to receive(:event).and_return(payload)

    MatchResultCheckJob.new(client: client).perform(target.id, 1)

    expect(target.reload.status).to eq("scheduled")
  end

  it "creates no fixtures and no predictions" do
    target = fixture(kickoff: 3.hours.ago, event_id: "i1007")
    allow(client).to receive(:event).and_return(
      event(status_name: "STATUS_FULL_TIME", home_score: 1, away_score: 0, id: "i1007")
    )

    expect {
      MatchResultCheckJob.new(client: client).perform(target.id, 1)
    }.not_to change { [Match.count, Prediction.count] }
  end

  it "does not enqueue a second check while one holds the lock" do
    fixture(kickoff: 3.hours.ago, event_id: "i1008")

    MatchResultDispatchJob.new.perform
    first = ActiveJob::Base.queue_adapter.enqueued_jobs.size
    MatchResultDispatchJob.new.perform
    second = ActiveJob::Base.queue_adapter.enqueued_jobs.size

    expect(first).to eq(1)
    expect(second).to eq(1)
  end
end
