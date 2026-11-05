require "rails_helper"

# Concurrent per-match checks must each get a ledger row.
#
# THE INCIDENT (2026-11-05)
# -------------------------
# The first live run enqueued four checks. The first recorded its row; the rest
# raised:
#
#   Sync::SyncRun::AlreadyRunning: a results synchronization is already running
#
# `sync_runs` has a partial unique index allowing ONE `running` row per kind, which
# is right for the daily synchronizations and wrong for per-match checks. The
# checks still ran, but their ledger rows were lost — the opposite of the
# observability the ledger exists for.
RSpec.describe "per-match check ledger" do
  let(:competition) { Competition.create!(name: "Ledger #{SecureRandom.hex(3)}", code: "E0") }
  let(:season) { Season.create!(competition: competition, name: "2026/27") }
  let(:home) { Team.create!(name: "Ledger Home #{SecureRandom.hex(3)}") }
  let(:away) { Team.create!(name: "Ledger Away #{SecureRandom.hex(3)}") }

  def fixture(event_id)
    match = Match.create!(competition: competition, season: season, home_team: home,
                          away_team: away, kickoff_at: 3.hours.ago, status: "scheduled")
    ExternalIdentifier.find_or_create_by!(provider: "espn", external_id: event_id) do |identifier|
      identifier.match = match
    end
    match
  end

  it "allows several match_check runs to be open at once" do
    first = Sync::SyncRun.start!(kind: Sync::SyncRun::MATCH_CHECK_KIND, trigger: "match_check")
    second = Sync::SyncRun.start!(kind: Sync::SyncRun::MATCH_CHECK_KIND, trigger: "match_check")

    expect(first).to be_persisted
    expect(second).to be_persisted
    expect(first.id).not_to eq(second.id)
  ensure
    [first, second].compact.each { |run| run.finish!(status: "succeeded") }
  end

  it "still allows only one open run per daily kind" do
    # The single-run guarantee the daily synchronizations rely on is unchanged.
    Sync::SyncRun.start!(kind: Sync::SyncRun::RESULT_KIND, trigger: "manual")

    expect {
      Sync::SyncRun.start!(kind: Sync::SyncRun::RESULT_KIND, trigger: "manual")
    }.to raise_error(Sync::SyncRun::AlreadyRunning)
  ensure
    Sync::SyncRun.for_kind(Sync::SyncRun::RESULT_KIND).running.each do |run|
      run.finish!(status: "succeeded")
    end
  end

  it "records a row for every check in a batch" do
    matches = %w[lg1 lg2 lg3].map { |id| fixture(id) }
    client = instance_double(Import::EspnClient)
    allow(client).to receive(:event).and_raise(Import::EspnClient::TransientError, "offline")

    matches.each { |match| MatchResultCheckJob.new(client: client).perform(match.id, 1) }

    rows = Sync::SyncRun.for_kind(Sync::SyncRun::MATCH_CHECK_KIND)
    expect(rows.count).to eq(3)
    expect(rows.pluck(:status).uniq).to eq(["failed"])
  end

  it "releases the lock when the check finishes" do
    # THE INCIDENT: the first live run left four advisory locks and four
    # bookkeeping rows behind, because nothing released the lock the dispatcher
    # acquired. Each would have blocked its match until the TTL takeover.
    match = fixture("lg5")
    Sync::ResultCheckLock.acquire(match.id)
    client = instance_double(Import::EspnClient)
    allow(client).to receive(:event).and_raise(Import::EspnClient::TransientError, "offline")

    MatchResultCheckJob.new(client: client).perform(match.id, 1)

    expect(Sync::ResultCheckLock.locked?(match.id)).to be(false)
    expect(Sync::ResultCheckLock.acquire(match.id)).to be(true)
  ensure
    Sync::ResultCheckLock.release(match.id)
  end

  it "releases the lock even when the check raises" do
    match = fixture("lg6")
    Sync::ResultCheckLock.acquire(match.id)
    client = instance_double(Import::EspnClient)
    allow(client).to receive(:event).and_raise(StandardError, "unexpected")

    expect {
      MatchResultCheckJob.new(client: client).perform(match.id, 1)
    }.to raise_error(StandardError, "unexpected")

    expect(Sync::ResultCheckLock.locked?(match.id)).to be(false)
  ensure
    Sync::ResultCheckLock.release(match.id)
  end

  it "records the rejection reason, not just the outcome" do
    match = fixture("lg4")
    client = instance_double(Import::EspnClient)
    # A payload whose clubs do not match the stored fixture.
    allow(client).to receive(:event).and_return(
      "id" => "lg4", "date" => 3.hours.ago.utc.iso8601, "season" => { "year" => 2026 },
      "competitions" => [{ "status" => { "type" => { "name" => "STATUS_FULL_TIME",
                                                     "state" => "post", "completed" => true } },
                           "competitors" => [
                             { "homeAway" => "home", "team" => { "id" => "unknown-a" }, "score" => "1" },
                             { "homeAway" => "away", "team" => { "id" => "unknown-b" }, "score" => "0" }
                           ] }]
    )

    MatchResultCheckJob.new(client: client).perform(match.id, 1)

    run = Sync::SyncRun.for_kind(Sync::SyncRun::MATCH_CHECK_KIND).order(:id).last
    expect(run.details["outcome"]).to eq("rejected")
    expect(run.details["rejections"]).not_to be_empty
    expect(run.details["rejections"].first["reason"]).to be_present
  end
end
