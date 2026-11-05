require "rails_helper"

# Result synchronization: what it may change, what it must refuse, and what it
# must never write at all.
#
# WHY THIS EXISTS
# ---------------
# On 2026-11-04 two fixtures (39662 in E0, 39676 in E1) had finished, the provider
# had published the scores, and the database still said `scheduled`. Results were
# collected by a throwaway script (`backend/tmp/ingest_recent_results.rb`) that
# bypassed the reconciler's conflict rules entirely. That is not a process that can
# carry prospective evidence: it had no preview, no conflict detection, and no
# record of what it decided.
#
# This synchronizer is the reusable version. It reuses the reconciler (the same
# class the fixture and discovery paths use, so duplicate prevention, reschedule
# handling and completed-result precedence cannot drift) and adds only what a
# RESULT run needs:
#
#   - preview mode that writes nothing and reports a per-match plan,
#   - an explicit conflict list a human must resolve,
#   - postponement/abandonment handled as a status change, never as a result,
#   - a ledger entry that says exactly what it inspected and what it changed.
RSpec.describe Sync::EspnResultSynchronizer do
  let(:competition) { Competition.create!(name: "Result Sync League #{SecureRandom.hex(3)}", code: "RS#{SecureRandom.hex(2)}") }
  let(:season) { Season.create!(competition: competition, name: "2026/27") }
  let(:home) { Team.create!(name: "Result Home #{SecureRandom.hex(3)}") }
  let(:away) { Team.create!(name: "Result Away #{SecureRandom.hex(3)}") }
  let(:day) { Date.new(2026, 11, 4) }

  let!(:fixture) do
    Match.create!(competition: competition, season: season, home_team: home, away_team: away,
                  kickoff_at: Time.utc(2026, 11, 4, 19, 45), status: "scheduled")
  end

  # Approved provider identity, so the reconciler can resolve both clubs. Tests
  # must not depend on the live mapping table.
  before do
    %w[esph espa].each_with_index do |external_id, index|
      identifier = ExternalIdentifier.find_or_initialize_by(provider: "espn", external_id: external_id)
      identifier.team = index.zero? ? home : away
      identifier.review_state = "approved"
      identifier.save!
    end
  end

  # One ESPN event, in ESPN's own shape.
  def event(status_name:, state: "post", home_score: nil, away_score: nil,
            event_id: "401990001", date: "2026-11-04T19:45Z")
    {
      "id" => event_id,
      "date" => date,
      "season" => { "year" => 2026 },
      "competitions" => [
        {
          "status" => { "type" => { "name" => status_name, "state" => state, "completed" => state == "post" } },
          "competitors" => [
            { "homeAway" => "home", "team" => { "id" => "esph", "displayName" => home.name },
              "score" => home_score&.to_s },
            { "homeAway" => "away", "team" => { "id" => "espa", "displayName" => away.name },
              "score" => away_score&.to_s },
          ],
        },
      ],
    }
  end

  let(:client) { instance_double(Import::EspnClient) }

  def synchronizer(events:)
    allow(client).to receive(:scoreboard).and_return(
      Import::EspnClient::Result.new(events: events, provider_ok: true)
    )
    described_class.new(client: client)
  end

  describe "preview mode" do
    it "writes nothing and reports the plan" do
      sync = synchronizer(events: [event(status_name: "STATUS_FULL_TIME", home_score: 2, away_score: 1)])

      report = sync.preview(league: "eng.1", season: season, date: day)

      expect(report.planned.map { |row| row[:action] }).to eq([:would_complete])
      expect(fixture.reload.status).to eq("scheduled")
      expect(fixture.home_score).to be_nil
    end

    it "records a preview run in the ledger without pretending it imported" do
      sync = synchronizer(events: [event(status_name: "STATUS_FULL_TIME", home_score: 2, away_score: 1)])

      sync.preview(league: "eng.1", season: season, date: day)

      run = Sync::SyncRun.for_kind("results").order(:id).last
      expect(run.details["mode"]).to eq("preview")
      expect(run.updated).to eq(0)
      expect(run.created).to eq(0)
    end
  end

  describe "applying results" do
    it "completes a scheduled fixture with both scores" do
      sync = synchronizer(events: [event(status_name: "STATUS_FULL_TIME", home_score: 2, away_score: 1)])

      report = sync.call(league: "eng.1", season: season, date: day)

      expect(report.completed.size).to eq(1)
      expect(fixture.reload.status).to eq("completed")
      expect([fixture.home_score, fixture.away_score]).to eq([2, 1])
    end

    it "treats an identical re-run as a no-op rather than an update" do
      sync = synchronizer(events: [event(status_name: "STATUS_FULL_TIME", home_score: 2, away_score: 1)])
      sync.call(league: "eng.1", season: season, date: day)

      second = sync.call(league: "eng.1", season: season, date: day)

      expect(second.completed).to be_empty
      expect(second.unchanged.size).to eq(1)
    end
  end

  describe "conflicting provider results" do
    before do
      fixture.update_columns(status: "completed", home_score: 2, away_score: 1)
    end

    it "refuses to overwrite a stored result and flags it for review" do
      sync = synchronizer(events: [event(status_name: "STATUS_FULL_TIME", home_score: 3, away_score: 1)])

      report = sync.call(league: "eng.1", season: season, date: day)

      expect(report.conflicts.size).to eq(1)
      expect(fixture.reload.home_score).to eq(2)
    end

    it "records the conflict in the ledger so it is not silent" do
      sync = synchronizer(events: [event(status_name: "STATUS_FULL_TIME", home_score: 3, away_score: 1)])

      sync.call(league: "eng.1", season: season, date: day)

      run = Sync::SyncRun.for_kind("results").order(:id).last
      expect(run.details["conflicts"].size).to eq(1)
      expect(fixture.reload.home_score).to eq(2)
    end

    it "stores the conflict with string keys so the ledger reads as plain JSON" do
      sync = synchronizer(events: [event(status_name: "STATUS_FULL_TIME", home_score: 3, away_score: 1)])

      sync.call(league: "eng.1", season: season, date: day)

      conflict = Sync::SyncRun.for_kind("results").order(:id).last.details["conflicts"].first
      expect(conflict.keys).to all(be_a(String))
      expect(conflict["stored_score"]).to eq([2, 1])
      expect(conflict["provider_score"]).to eq([3, 1])
      # Round-trips through JSON without losing or reshaping anything.
      expect(JSON.parse(conflict.to_json)).to eq(conflict)
    end

    it "does not change the result when a completed match is reported as postponed" do
      sync = synchronizer(events: [event(status_name: "STATUS_POSTPONED", state: "post")])

      report = sync.call(league: "eng.1", season: season, date: day)

      expect(report.conflicts.size).to eq(1)
      expect(fixture.reload.status).to eq("completed")
      expect(fixture.home_score).to eq(2)
    end
  end

  describe "postponed and abandoned fixtures" do
    it "marks a scheduled fixture postponed" do
      sync = synchronizer(events: [event(status_name: "STATUS_POSTPONED", state: "post")])

      sync.call(league: "eng.1", season: season, date: day)

      expect(fixture.reload.status).to eq("postponed")
      expect(fixture.home_score).to be_nil
    end

    it "marks a scheduled fixture cancelled when the provider abandons it" do
      # ESPN reports an abandoned match as STATUS_ABANDONED and the adapter maps
      # that to `cancelled`; the point of the test is that NO SCORE is invented.
      sync = synchronizer(events: [event(status_name: "STATUS_ABANDONED", state: "post")])

      sync.call(league: "eng.1", season: season, date: day)

      expect(fixture.reload.status).to eq("cancelled")
      expect(fixture.home_score).to be_nil
      expect(fixture.away_score).to be_nil
    end

    it "marks an in-play fixture in_progress without a score" do
      # The status follows the provider — that is the live-state feed — but no
      # result is recorded until the event is final.
      sync = synchronizer(events: [event(status_name: "STATUS_IN_PROGRESS", state: "in")])

      sync.call(league: "eng.1", season: season, date: day)

      expect(fixture.reload.status).to eq("in_progress")
      expect(fixture.home_score).to be_nil
    end
  end

  describe "rescheduled fixtures" do
    # The fixture is linked by APPROVED PROVIDER IDENTITY, which is how it will be
    # linked in practice — the provider keeps the same event id when a match moves.
    # Without the identity link, `resolve_match` falls back to teams + the kickoff
    # DAY, and a fixture moved to another month would simply not be found: that is
    # correct (a result run must not guess), but it is not a reschedule test.
    before do
      ExternalIdentifier.find_or_create_by!(provider: "espn", external_id: "401990001") do |identifier|
        identifier.match = fixture
      end
    end

    it "reports a kickoff change and does not treat the row as a result" do
      sync = synchronizer(events: [event(status_name: "STATUS_SCHEDULED", state: "pre",
                                         date: "2026-12-01T20:00Z")])

      report = sync.call(league: "eng.1", season: season, date: day)

      expect(report.rescheduled.size).to eq(1)
      expect(fixture.reload.status).to eq("scheduled")
      expect(fixture.kickoff_at.utc).to eq(Time.utc(2026, 12, 1, 20, 0))
    end

    it "does not invent a result when the rescheduled match is later completed" do
      # Step 1: rescheduled.
      synchronizer(events: [event(status_name: "STATUS_SCHEDULED", state: "pre",
                                  date: "2026-12-01T20:00Z")])
        .call(league: "eng.1", season: season, date: day)

      # Step 2: the new date arrives with a final score. It applies to the SAME row,
      # whose identity is unchanged — the prediction tied to it, if any, was issued
      # against the OLD kickoff and is rejected by the eligibility gate.
      sync = synchronizer(events: [event(status_name: "STATUS_FULL_TIME", state: "post",
                                         home_score: 1, away_score: 1,
                                         date: "2026-12-01T20:00Z")])
      report = sync.call(league: "eng.1", season: season, date: Date.new(2026, 12, 1))

      expect(report.completed.size).to eq(1)
      expect(fixture.reload.status).to eq("completed")
      expect([fixture.home_score, fixture.away_score]).to eq([1, 1])
    end
  end

  describe "identity and association" do
    it "counts a row for an unmapped club as rejected rather than guessing" do
      unmapped = event(status_name: "STATUS_FULL_TIME", home_score: 1, away_score: 0)
      unmapped["competitions"][0]["competitors"][0]["team"]["id"] = "99999999"

      report = synchronizer(events: [unmapped]).call(league: "eng.1", season: season, date: day)

      expect(report.rejected.size).to eq(1)
      expect(fixture.reload.status).to eq("scheduled")
    end

    it "ignores an event that belongs to another season" do
      other = Season.create!(competition: competition, name: "2025/26")
      report = synchronizer(events: [event(status_name: "STATUS_FULL_TIME", home_score: 1, away_score: 0)])
        .call(league: "eng.1", season: other, date: day)

      expect(report.completed).to be_empty
      expect(fixture.reload.status).to eq("scheduled")
    end

    it "ignores an event for an unknown fixture instead of creating one" do
      sync = synchronizer(events: [event(status_name: "STATUS_FULL_TIME", home_score: 1, away_score: 0,
                                         event_id: "401990999")])

      expect { sync.call(league: "eng.1", season: season, date: day) }.not_to change(Match, :count)
    end
  end

  describe "provider failure" do
    it "closes the ledger as failed without writing anything" do
      allow(client).to receive(:scoreboard).and_raise(Import::EspnClient::TransientError, "boom")
      sync = described_class.new(client: client)

      sync.call(league: "eng.1", season: season, date: day)

      run = Sync::SyncRun.for_kind("results").order(:id).last
      expect(run.status).to eq("failed")
      expect(fixture.reload.status).to eq("scheduled")
    end
  end

  describe "summary" do
    it "counts every inspected event exactly once" do
      sync = synchronizer(events: [
                            event(status_name: "STATUS_FULL_TIME", home_score: 2, away_score: 1),
                            event(status_name: "STATUS_IN_PROGRESS", state: "in", event_id: "401990002"),
                          ])

      report = sync.preview(league: "eng.1", season: season, date: day)

      expect(report.fetched).to eq(2)
      expect(report.inspected).to eq(2)
    end
  end
end
