require "rails_helper"

# The dispatcher decides WHICH matches are due a result check and enqueues one
# `MatchResultCheckJob` per match. It never calls ESPN itself.
#
# WHY A SEPARATE JOB
# ------------------
# `MatchResultCheckJob` answers "what happened in this one match?". Something has
# to answer "which matches are due?" — and that question is a database query, not
# a provider request. Keeping them apart means the dispatcher can run every five
# minutes without spending a single ESPN request, and a provider outage cannot
# stop the queue from being filled.
RSpec.describe MatchResultDispatchJob do
  let(:competition) { Competition.create!(name: "Dispatch League #{SecureRandom.hex(3)}", code: "E0") }
  let(:season) { Season.create!(competition: competition, name: "2026/27") }
  let(:home) { Team.create!(name: "Dispatch Home #{SecureRandom.hex(3)}") }
  let(:away) { Team.create!(name: "Dispatch Away #{SecureRandom.hex(3)}") }

  def fixture(kickoff:, status: "scheduled", event_id: nil, approved: true)
    # A completed match must carry both scores (model validation), so the fixture
    # supplies them rather than tripping an unrelated rule.
    scores = status == "completed" ? { home_score: 1, away_score: 0 } : {}
    match = Match.create!(competition: competition, season: season, home_team: home,
                          away_team: away, kickoff_at: kickoff, status: status, **scores)
    if event_id
      identifier = ExternalIdentifier.find_or_initialize_by(provider: "espn", external_id: event_id)
      identifier.match = match
      identifier.review_state = approved ? "approved" : "proposed"
      identifier.save!
    end
    match
  end

  def dispatch
    described_class.new.perform
  end

  before { ActiveJob::Base.queue_adapter = :test }

  describe "eligibility" do
    it "selects a scheduled match past the completion buffer" do
      match = fixture(kickoff: 3.hours.ago, event_id: "d1001")

      summary = dispatch

      expect(summary[:eligible]).to eq(1)
      expect(summary[:enqueued]).to eq(1)
      expect(enqueued_count).to eq(1)
    end

    it "excludes a match whose kickoff is in the future" do
      fixture(kickoff: 2.hours.from_now, event_id: "d1002")

      summary = dispatch

      expect(summary[:eligible]).to eq(0)
      expect(summary[:enqueued]).to eq(0)
    end

    it "excludes a match still inside the completion buffer" do
      # 2h15m is the buffer; 2h is inside it.
      fixture(kickoff: 2.hours.ago, event_id: "d1003")

      expect(dispatch[:enqueued]).to eq(0)
    end

    it "includes a match just past the buffer" do
      fixture(kickoff: (2.hours + 20.minutes).ago, event_id: "d1004")

      expect(dispatch[:enqueued]).to eq(1)
    end

    it "excludes a match with no ESPN event identifier" do
      fixture(kickoff: 3.hours.ago)

      summary = dispatch

      expect(summary[:enqueued]).to eq(0)
      expect(summary[:invalid_mappings]).to eq(1)
    end

    it "excludes a match whose ESPN mapping is not approved" do
      fixture(kickoff: 3.hours.ago, event_id: "d1005", approved: false)

      summary = dispatch

      expect(summary[:enqueued]).to eq(0)
      expect(summary[:invalid_mappings]).to eq(1)
    end

    it "excludes a match whose competition has no verified ESPN league" do
      other = Competition.create!(name: "Unmapped #{SecureRandom.hex(3)}", code: "ZZ9")
      other_season = Season.create!(competition: other, name: "2026/27")
      match = Match.create!(competition: other, season: other_season, home_team: home,
                            away_team: away, kickoff_at: 3.hours.ago, status: "scheduled")
      ExternalIdentifier.find_or_create_by!(provider: "espn", external_id: "d1006") do |identifier|
        identifier.match = match
      end

      summary = dispatch

      expect(summary[:enqueued]).to eq(0)
      expect(summary[:invalid_mappings]).to eq(1)
    end

    it "excludes a completed match" do
      fixture(kickoff: 3.hours.ago, status: "completed", event_id: "d1007")

      expect(dispatch[:enqueued]).to eq(0)
    end

    it "excludes a match past the maximum retry window" do
      fixture(kickoff: 30.hours.ago, event_id: "d1008")

      summary = dispatch

      expect(summary[:enqueued]).to eq(0)
      expect(summary[:expired]).to eq(1)
    end

    it "handles an empty candidate set" do
      summary = dispatch

      expect(summary[:considered]).to eq(0)
      expect(summary[:enqueued]).to eq(0)
      expect(summary[:errors]).to be_empty
    end
  end

  describe "enqueueing" do
    it "enqueues one job per eligible match across competitions" do
      other = Competition.create!(name: "Second #{SecureRandom.hex(3)}", code: "E1")
      other_season = Season.create!(competition: other, name: "2026/27")
      fixture(kickoff: 3.hours.ago, event_id: "d2001")
      Match.create!(competition: other, season: other_season, home_team: home,
                        away_team: away, kickoff_at: 4.hours.ago, status: "scheduled")
      ExternalIdentifier.find_or_create_by!(provider: "espn", external_id: "d2002") do |identifier|
        identifier.match = Match.order(:id).last
      end

      summary = dispatch

      expect(summary[:eligible]).to eq(2)
      expect(summary[:enqueued]).to eq(2)
      expect(enqueued_count).to eq(2)
    end

    it "does not call ESPN" do
      fixture(kickoff: 3.hours.ago, event_id: "d2003")
      expect(Import::EspnClient).not_to receive(:new)

      dispatch
    end

    it "records a ledger row for the dispatch run" do
      fixture(kickoff: 3.hours.ago, event_id: "d2004")

      dispatch

      run = Sync::SyncRun.for_kind("results").order(:id).last
      expect(run.details["dispatcher"]).to be(true)
      expect(run.details["enqueued"]).to eq(1)
    end
  end

  describe "database errors" do
    it "reports the error instead of raising" do
      allow(Match).to receive(:where).and_raise(ActiveRecord::StatementInvalid, "boom")

      summary = dispatch

      expect(summary[:errors]).not_to be_empty
      expect(summary[:enqueued]).to eq(0)
    end

    it "does not record a successful dispatch when the query failed" do
      allow(Match).to receive(:where).and_raise(ActiveRecord::StatementInvalid, "boom")

      dispatch

      run = Sync::SyncRun.for_kind("results").order(:id).last
      expect(run.status).to eq("failed")
      expect(run.details["errors"]).not_to be_empty
    end
  end

  describe "batch limit" do
    it "never considers more than BATCH_SIZE matches in one run" do
      # The limit is a property of the query, so it is asserted on the query rather
      # than by creating 201 fixtures.
      relation = Match.where(status: "scheduled")
      allow(Match).to receive(:where).and_return(relation)
      expect(relation).to receive(:limit).with(described_class::BATCH_SIZE).and_call_original

      dispatch
    end
  end

  # The test adapter records each enqueue as a hash with STRING keys, and
  # `arguments` is EMPTY in this ActiveJob version because `perform_later`
  # forwards the arguments to the constructor (handout §23.6). The match id is
  # therefore not recoverable from the adapter record, so these assertions count
  # the enqueued jobs and check their class — which is what the dispatcher is
  # responsible for. The per-match behaviour is covered by the lock spec and by
  # `MatchResultCheckJob`'s own spec.
  def enqueued_jobs
    ActiveJob::Base.queue_adapter.enqueued_jobs
      .select { |job| job["job_class"] == "MatchResultCheckJob" }
  end

  def enqueued_count
    enqueued_jobs.size
  end
end
