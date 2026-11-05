require "rails_helper"

# Normalises ESPN scoreboard payloads.
#
# ESPN is used here because it serves the CURRENT season without a key, which
# API-Football's free tier does not. The normalisation follows the same rules as
# the API-Football adapter, and for the same reason: a live score must never
# become a final result.
#
# Status is read from the `state` field (`pre`/`in`/`post`) plus `completed`,
# NOT from the status name. The name varies by sport and changes as ESPN adds
# new ones; `state` is the stable contract.
RSpec.describe Import::EspnAdapter do
  subject(:adapter) { described_class.new }

  def event(id: "704559", state: "post", completed: true, status_name: "STATUS_FULL_TIME",
            home: "382", away: "424", home_score: "2", away_score: "1",
            date: "2026-10-25T14:00Z")
    {
      "id" => id,
      "date" => date,
      "season" => { "year" => 2026, "slug" => "2026-27-english-premier-league" },
      "competitions" => [{
        "status" => {
          "clock" => 5400,
          "displayClock" => "90'",
          "type" => {
            "id" => "28", "name" => status_name, "state" => state,
            "completed" => completed, "description" => "", "shortDetail" => "",
          },
        },
        "competitors" => [
          { "id" => home, "homeAway" => "home", "score" => home_score,
            "team" => { "id" => home, "displayName" => "Manchester City", "abbreviation" => "MNC" } },
          { "id" => away, "homeAway" => "away", "score" => away_score,
            "team" => { "id" => away, "displayName" => "Fulham", "abbreviation" => "FUL" } },
        ],
      }],
    }
  end

  describe "status mapping" do
    it "maps a completed post-state fixture to completed" do
      expect(adapter.normalize_fixture(event).status).to eq("completed")
    end

    it "maps an in-progress fixture to in_progress" do
      row = adapter.normalize_fixture(event(state: "in", completed: false, status_name: "STATUS_IN_PROGRESS"))
      expect(row.status).to eq("in_progress")
    end

    it "maps a pre-state fixture to scheduled" do
      row = adapter.normalize_fixture(event(state: "pre", completed: false, status_name: "STATUS_SCHEDULED"))
      expect(row.status).to eq("scheduled")
    end

    it "maps a postponed event to postponed" do
      row = adapter.normalize_fixture(event(state: "post", completed: false, status_name: "STATUS_POSTPONED"))
      expect(row.status).to eq("postponed")
    end

    it "maps a cancelled or abandoned event to cancelled" do
      expect(adapter.normalize_fixture(event(state: "post", completed: false, status_name: "STATUS_CANCELED")).status).to eq("cancelled")
      expect(adapter.normalize_fixture(event(state: "post", completed: false, status_name: "STATUS_ABANDONED")).status).to eq("cancelled")
    end

    it "does not trust `completed` alone when the name says postponed" do
      # ESPN has been known to set completed on a postponed fixture. A cancelled
      # or postponed match must never be imported as a finished result.
      row = adapter.normalize_fixture(event(state: "post", completed: true, status_name: "STATUS_POSTPONED"))
      expect(row.status).to eq("postponed")
      expect(row.home_score).to be_nil
    end

    it "returns nil for an unknown state rather than guessing" do
      expect(adapter.normalize_fixture(event(state: "weird", completed: false)).status).to be_nil
    end
  end

  describe "scores" do
    it "keeps the final score for a completed match" do
      row = adapter.normalize_fixture(event(state: "post", completed: true, home_score: "3", away_score: "0"))
      expect([row.home_score, row.away_score]).to eq([3, 0])
    end

    it "strips the score from a live match so it cannot become a label" do
      row = adapter.normalize_fixture(event(state: "in", completed: false, home_score: "1", away_score: "0"))
      expect(row.home_score).to be_nil
      expect(row.away_score).to be_nil
    end

    it "treats a completed match with no scores as having no result" do
      row = adapter.normalize_fixture(event(state: "post", completed: true, home_score: nil, away_score: nil))
      expect(row.home_score).to be_nil
    end

    it "keeps a genuine 0-0" do
      row = adapter.normalize_fixture(event(state: "post", completed: true, home_score: "0", away_score: "0"))
      expect([row.home_score, row.away_score]).to eq([0, 0])
    end
  end

  describe "identity" do
    it "identifies the provider and fixture key" do
      row = adapter.normalize_fixture(event(id: "704559"))
      expect(row.provider).to eq("espn")
      expect(row.provider_key).to eq("704559")
    end

    it "identifies home and away by homeAway, not by array order" do
      payload = event
      payload["competitions"][0]["competitors"] = payload["competitions"][0]["competitors"].reverse
      row = adapter.normalize_fixture(payload)

      expect(row.home_provider_team_id).to eq("382")
      expect(row.away_provider_team_id).to eq("424")
    end

    it "parses kickoff into UTC" do
      row = adapter.normalize_fixture(event(date: "2026-10-25T15:00Z"))
      expect(row.kickoff_at.utc.iso8601).to eq("2026-10-25T15:00:00Z")
    end

    it "carries the provider team names and abbreviations for mapping" do
      row = adapter.normalize_fixture(event)
      expect(row.home_team_name).to eq("Manchester City")
      expect(row.away_team_name).to eq("Fulham")
    end
  end

  describe "rejection" do
    it "returns nil without an event id" do
      payload = event
      payload.delete("id")
      expect(adapter.normalize_fixture(payload)).to be_nil
    end

    it "returns nil when there are not exactly two competitors" do
      payload = event
      payload["competitions"][0]["competitors"].pop
      expect(adapter.normalize_fixture(payload)).to be_nil
    end

    it "returns nil when home and away resolve to the same team" do
      payload = event(home: "382", away: "382")
      expect(adapter.normalize_fixture(payload)).to be_nil
    end

    it "returns nil for a malformed date" do
      expect(adapter.normalize_fixture(event(date: "not-a-date"))).to be_nil
    end

    it "returns nil when the payload is not a hash" do
      expect(adapter.normalize_fixture("nope")).to be_nil
    end
  end
end
