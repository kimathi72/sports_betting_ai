require "rails_helper"

# Normalises API-Football fixture payloads.
#
# The adapter is pure: it turns provider hashes into internal shapes and never
# touches the database. That is what makes these fixtures (captured from the
# real API) enough to prove the mapping rules, including the ones that protect
# historical data.
RSpec.describe Import::ApiFootballAdapter do
  subject(:adapter) { described_class.new }

  # Trimmed from a real response; the fields the adapter reads are exact.
  def fixture(id: 1208021, status_short: "FT", status_long: "Match Finished",
              home: 1, away: 0, date: "2024-08-16T19:00:00+00:00")
    {
      "fixture" => {
        "id" => id,
        "date" => date,
        "timezone" => "UTC",
        "status" => { "long" => status_long, "short" => status_short, "elapsed" => 90 },
      },
      "league" => { "id" => 39, "name" => "Premier League", "country" => "England", "season" => 2024 },
      "teams" => {
        "home" => { "id" => 33, "name" => "Manchester United" },
        "away" => { "id" => 36, "name" => "Fulham" },
      },
      "goals" => { "home" => home, "away" => away },
    }
  end

  describe "status mapping" do
    it "maps finished codes to completed" do
      %w[FT AET PEN].each do |code|
        row = adapter.normalize_fixture(fixture(status_short: code))
        expect(row.status).to eq("completed"), "expected #{code} to be completed"
      end
    end

    it "maps live codes to in_progress, never completed" do
      # The distinction protects training labels: a live score must never be
      # imported as a final result.
      %w[1H HT 2H ET BT P SUSP INT].each do |code|
        row = adapter.normalize_fixture(fixture(status_short: code))
        expect(row.status).to eq("in_progress"), "expected #{code} to be in_progress"
      end
    end

    it "maps postponement and abandonment codes" do
      expect(adapter.normalize_fixture(fixture(status_short: "PST")).status).to eq("postponed")
      expect(adapter.normalize_fixture(fixture(status_short: "ABD")).status).to eq("cancelled")
      expect(adapter.normalize_fixture(fixture(status_short: "CANC")).status).to eq("cancelled")
      expect(adapter.normalize_fixture(fixture(status_short: "AWD")).status).to eq("cancelled")
    end

    it "maps upcoming codes to scheduled" do
      %w[TBD NS].each do |code|
        expect(adapter.normalize_fixture(fixture(status_short: code)).status).to eq("scheduled")
      end
    end

    it "leaves an unknown status out rather than guessing" do
      row = adapter.normalize_fixture(fixture(status_short: "XYZ"))
      expect(row.status).to be_nil
    end
  end

  describe "scores" do
    it "takes the final score only for a completed match" do
      row = adapter.normalize_fixture(fixture(status_short: "FT", home: 2, away: 1))
      expect([row.home_score, row.away_score]).to eq([2, 1])
    end

    it "drops the score for a live match so it cannot become a label" do
      row = adapter.normalize_fixture(fixture(status_short: "2H", home: 1, away: 0))
      expect(row.home_score).to be_nil
      expect(row.away_score).to be_nil
    end

    it "drops the score for a scheduled match even if a value is present" do
      row = adapter.normalize_fixture(fixture(status_short: "NS", home: 0, away: 0))
      expect(row.home_score).to be_nil
    end

    it "keeps a genuine 0-0 as two zeros, not as missing" do
      row = adapter.normalize_fixture(fixture(status_short: "FT", home: 0, away: 0))
      expect([row.home_score, row.away_score]).to eq([0, 0])
    end

    it "treats a completed match with a null goal as having no score" do
      row = adapter.normalize_fixture(fixture(status_short: "FT", home: nil, away: nil))
      expect(row.home_score).to be_nil
    end
  end

  describe "identity" do
    it "exposes the provider fixture id as a string key" do
      row = adapter.normalize_fixture(fixture(id: 1208021))
      expect(row.provider).to eq("api_football")
      expect(row.provider_key).to eq("1208021")
    end

    it "carries the provider team and league identifiers for mapping" do
      row = adapter.normalize_fixture(fixture)
      expect(row.home_provider_team_id).to eq("33")
      expect(row.away_provider_team_id).to eq("36")
      expect(row.provider_league_id).to eq("39")
      expect(row.provider_season_year).to eq("2024")
    end

    it "parses kickoff into UTC" do
      row = adapter.normalize_fixture(fixture(date: "2024-08-16T19:00:00+00:00"))
      expect(row.kickoff_at.utc.iso8601).to eq("2024-08-16T19:00:00Z")
    end

    it "converts a non-UTC offset to UTC rather than assuming it is already UTC" do
      row = adapter.normalize_fixture(fixture(date: "2024-08-16T21:00:00+02:00"))
      expect(row.kickoff_at.utc.iso8601).to eq("2024-08-16T19:00:00Z")
    end
  end

  describe "rejection" do
    it "returns nil for a payload with no fixture id" do
      payload = fixture
      payload["fixture"].delete("id")
      expect(adapter.normalize_fixture(payload)).to be_nil
    end

    it "returns nil for a payload with no teams" do
      payload = fixture
      payload.delete("teams")
      expect(adapter.normalize_fixture(payload)).to be_nil
    end

    it "returns nil for a malformed date instead of inventing a kickoff" do
      expect(adapter.normalize_fixture(fixture(date: "not-a-date"))).to be_nil
    end
  end

  describe "ambiguity" do
    it "flags a fixture whose two provider team ids are identical" do
      payload = fixture
      payload["teams"]["away"]["id"] = 33
      expect(adapter.normalize_fixture(payload)).to be_nil
    end
  end
end
