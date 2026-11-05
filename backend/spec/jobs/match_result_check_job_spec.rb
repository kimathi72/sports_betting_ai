require "rails_helper"

# One match, one provider request.
#
# WHY THIS JOB EXISTS
# -------------------
# `Sync::EspnResultSynchronizer` is DATE-scoped: it fetches a whole scoreboard day
# and iterates every event. Checking a single finished fixture that way costs a
# full day's payload and touches every other match on that day. This job asks ESPN
# about exactly one event and applies the answer through the same reconciliation
# rules.
#
# WHAT IT MUST NEVER DO
# ---------------------
#   - create a fixture,
#   - overwrite a trusted completed result,
#   - accept a result for a different match than the one it was asked about,
#   - treat "kickoff has passed" as "the match has finished",
#   - retry forever.
RSpec.describe MatchResultCheckJob do
  # A REAL catalogue code: the job resolves the ESPN league from
  # `EspnLeagueCoverage::VERIFIED`, so a made-up code would make every example
  # pass for the wrong reason ("no ESPN league") instead of exercising the check.
  let(:competition) { Competition.create!(name: "Check League #{SecureRandom.hex(3)}", code: "E0") }
  let(:season) { Season.create!(competition: competition, name: "2026/27") }
  let(:home) { Team.create!(name: "Check Home #{SecureRandom.hex(3)}") }
  let(:away) { Team.create!(name: "Check Away #{SecureRandom.hex(3)}") }
  let(:event_id) { "401990001" }

  let!(:match) do
    Match.create!(competition: competition, season: season, home_team: home, away_team: away,
                  kickoff_at: 3.hours.ago, status: "scheduled")
  end

  before do
    %w[ckh cka].each_with_index do |external_id, index|
      identifier = ExternalIdentifier.find_or_initialize_by(provider: "espn", external_id: external_id)
      identifier.team = index.zero? ? home : away
      identifier.review_state = "approved"
      identifier.save!
    end
    ExternalIdentifier.find_or_create_by!(provider: "espn", external_id: event_id) do |identifier|
      identifier.match = match
    end
  end

  # One ESPN event, in the shape the adapter parses.
  def event(status_name:, state: "post", home_score: nil, away_score: nil, id: event_id)
    {
      "id" => id,
      "date" => match.kickoff_at.utc.iso8601,
      "season" => { "year" => 2026 },
      "competitions" => [
        {
          "status" => { "type" => { "name" => status_name, "state" => state,
                                   "completed" => state == "post" } },
          "competitors" => [
            { "homeAway" => "home", "team" => { "id" => "ckh", "displayName" => home.name },
              "score" => home_score&.to_s },
            { "homeAway" => "away", "team" => { "id" => "cka", "displayName" => away.name },
              "score" => away_score&.to_s },
          ],
        },
      ],
    }
  end

  let(:client) { instance_double(Import::EspnClient) }

  def stub_event(payload)
    allow(client).to receive(:event).and_return(payload)
  end

  # `described_class.new.perform(a, b)` would pass the arguments to `new`, not to
  # `perform` — the job takes no constructor arguments under Sidekiq. Every call
  # site therefore builds the job first and calls `perform` on the instance.
  def job
    described_class.new(client: client)
  end

  describe "provider access" do
    it "requests only the specified event, never a scoreboard" do
      stub_event(event(status_name: "STATUS_FULL_TIME", home_score: 2, away_score: 1))
      expect(client).to receive(:event).with(league: "eng.1", event_id: event_id).once
      expect(client).not_to receive(:scoreboard)

      job.perform(match.id, 1)
    end

    it "does not call the provider at all when the match is not eligible" do
      match.update_columns(status: "completed", home_score: 1, away_score: 0)
      expect(client).not_to receive(:event)

      job.perform(match.id, 1)
    end
  end

  describe "applying a final result" do
    it "completes the match with both scores" do
      stub_event(event(status_name: "STATUS_FULL_TIME", home_score: 2, away_score: 1))

      job.perform(match.id, 1)

      match.reload
      expect(match.status).to eq("completed")
      expect([match.home_score, match.away_score]).to eq([2, 1])
    end

    it "records the attempt in the ledger" do
      stub_event(event(status_name: "STATUS_FULL_TIME", home_score: 2, away_score: 1))

      job.perform(match.id, 1)

      run = Sync::SyncRun.for_kind(Sync::SyncRun::MATCH_CHECK_KIND).order(:id).last
      expect(run.details["match_id"]).to eq(match.id)
      expect(run.details["event_id"]).to eq(event_id)
      expect(run.details["outcome"]).to eq("completed")
    end
  end

  describe "no result published yet" do
    it "records an in-progress match as in_progress, with no score" do
      # The adapter maps a live event to `in_progress` (STATE_STATUS['in']). The
      # job's contract is that it never records a SCORE before the event is final;
      # the status itself follows the provider, which is the live-state feed.
      stub_event(event(status_name: "STATUS_IN_PROGRESS", state: "in"))

      job.perform(match.id, 1)

      expect(match.reload.status).to eq("in_progress")
      expect(match.home_score).to be_nil
    end

    it "leaves a match unchanged when the event is still pre-match" do
      stub_event(event(status_name: "STATUS_SCHEDULED", state: "pre"))

      job.perform(match.id, 1)

      expect(match.reload.status).to eq("scheduled")
    end

    it "does not treat a generic completed flag as a final result" do
      # `completed: true` with a non-final status name must not complete the match.
      payload = event(status_name: "STATUS_SUSPENDED", state: "post")
      stub_event(payload)

      job.perform(match.id, 1)

      expect(match.reload.status).not_to eq("completed")
      expect(match.home_score).to be_nil
    end
  end

  describe "postponed, cancelled, abandoned and suspended" do
    it "marks a postponed match postponed without a score" do
      stub_event(event(status_name: "STATUS_POSTPONED", state: "post"))

      job.perform(match.id, 1)

      expect(match.reload.status).to eq("postponed")
      expect(match.home_score).to be_nil
    end

    it "marks a cancelled match cancelled without a score" do
      stub_event(event(status_name: "STATUS_CANCELED", state: "post"))

      job.perform(match.id, 1)

      expect(match.reload.status).to eq("cancelled")
      expect(match.home_score).to be_nil
    end

    it "marks an abandoned match cancelled without inventing a score" do
      stub_event(event(status_name: "STATUS_ABANDONED", state: "post"))

      job.perform(match.id, 1)

      expect(match.reload.status).to eq("cancelled")
      expect(match.home_score).to be_nil
    end

    it "never records a score for a suspended match" do
      # `STATUS_SUSPENDED` maps to `in_progress` in the adapter. The point of the
      # test is that a suspended match is NOT completed and carries no score.
      stub_event(event(status_name: "STATUS_SUSPENDED", state: "in"))

      job.perform(match.id, 1)

      expect(match.reload.status).not_to eq("completed")
      expect(match.home_score).to be_nil
    end
  end

  describe "result integrity" do
    # A completed match is settled: the job does not re-fetch it, because the
    # reconciler would refuse to change it anyway and the dispatcher never selects
    # one. The overwrite guarantee is therefore asserted at the layer that owns it
    # — the synchronizer — and the job's own behaviour is asserted here.
    it "does not re-fetch a match that already has a trusted result" do
      match.update_columns(status: "completed", home_score: 2, away_score: 1)
      expect(client).not_to receive(:event)

      job.perform(match.id, 1)

      match.reload
      expect([match.home_score, match.away_score]).to eq([2, 1])
    end

    it "records a completed match as ineligible, with the reason" do
      match.update_columns(status: "completed", home_score: 2, away_score: 1)

      job.perform(match.id, 1)

      run = Sync::SyncRun.for_kind(Sync::SyncRun::MATCH_CHECK_KIND).order(:id).last
      expect(run.details["outcome"]).to eq("ineligible")
      expect(run.details["reason"]).to eq("match is completed")
    end

    it "does not create a fixture when the event resolves to no match" do
      stub_event(event(status_name: "STATUS_FULL_TIME", home_score: 1, away_score: 0, id: "401999999"))

      expect { job.perform(match.id, 1) }.not_to change(Match, :count)
    end

    it "refuses an event that resolves to a different match" do
      # The match under test is linked to event 401990777, but the PROVIDER payload
      # for that event describes a different fixture (the teams are swapped). The
      # job must refuse rather than write a result to the wrong row.
      #
      # The enclosing `before` marks `match` completed; this example is about a
      # SCHEDULED fixture, so it is reset here rather than inheriting that state.
      match.update_columns(status: "scheduled", home_score: nil, away_score: nil)
      other = Match.create!(competition: competition, season: season, home_team: away,
                            away_team: home, kickoff_at: 3.hours.ago, status: "scheduled")
      ExternalIdentifier.where(provider: "espn", external_id: event_id).delete_all
      ExternalIdentifier.find_or_create_by!(provider: "espn", external_id: "401990777") do |identifier|
        identifier.match = match
      end
      ExternalIdentifier.find_or_create_by!(provider: "espn", external_id: "401990778") do |identifier|
        identifier.match = other
      end

      # The payload's teams resolve to `other`, not to `match`.
      payload = event(status_name: "STATUS_FULL_TIME", home_score: 4, away_score: 0, id: "401990777")
      payload["competitions"][0]["competitors"][0]["team"]["id"] = "cka"
      payload["competitions"][0]["competitors"][1]["team"]["id"] = "ckh"
      stub_event(payload)

      job.perform(match.id, 1)

      expect(match.reload.status).to eq("scheduled")
      expect(other.reload.status).to eq("scheduled")
    end

    it "does not create or change predictions" do
      stub_event(event(status_name: "STATUS_FULL_TIME", home_score: 2, away_score: 1))

      expect { job.perform(match.id, 1) }.not_to change(Prediction, :count)
    end
  end

  describe "provider failures" do
    it "leaves the match untouched on a timeout" do
      allow(client).to receive(:event).and_raise(Import::EspnClient::TransientError, "timed out")

      job.perform(match.id, 1)

      expect(match.reload.status).to eq("scheduled")
    end

    it "records the failure in the ledger" do
      allow(client).to receive(:event).and_raise(Import::EspnClient::TransientError, "timed out")

      job.perform(match.id, 1)

      run = Sync::SyncRun.for_kind(Sync::SyncRun::MATCH_CHECK_KIND).order(:id).last
      expect(run.status).to eq("failed")
      expect(run.details["outcome"]).to eq("provider_error")
    end
  end

  describe "idempotency" do
    it "is a no-op on a second run after the result was applied" do
      stub_event(event(status_name: "STATUS_FULL_TIME", home_score: 2, away_score: 1))
      job.perform(match.id, 1)

      expect(client).not_to receive(:event)
      job.perform(match.id, 1)

      expect(match.reload.home_score).to eq(2)
    end
  end

  describe "retry window" do
    it "stops checking once the maximum window has passed" do
      match.update_columns(kickoff_at: 30.hours.ago)
      expect(client).not_to receive(:event)

      job.perform(match.id, 1)

      run = Sync::SyncRun.for_kind(Sync::SyncRun::MATCH_CHECK_KIND).order(:id).last
      expect(run.details["outcome"]).to eq("unresolved")
    end
  end
end
