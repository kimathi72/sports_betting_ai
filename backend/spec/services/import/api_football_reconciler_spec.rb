require "rails_helper"

# Writes normalised API-Football rows into the canonical tables.
#
# These are the tests that protect historical data. The rules under test:
#
#   - a fixture already known (by provider id OR by teams+date) is never
#     duplicated;
#   - a completed result is never overwritten by different data;
#   - a live match never writes a final score;
#   - a reschedule updates the kickoff;
#   - nothing is created for a team that cannot be identified unambiguously.
RSpec.describe Import::ApiFootballReconciler do
  let(:competition) { Competition.create!(name: "Premier League", code: "E0") }
  let(:season) { Season.create!(competition: competition, name: "2024/25") }
  let(:home) { Team.create!(name: "Manchester United") }
  let(:away) { Team.create!(name: "Fulham") }
  let(:reconciler) { described_class.new }
  let(:adapter) { Import::ApiFootballAdapter.new }

  def payload(id: 1208021, status: "FT", home_goals: 1, away_goals: 0,
              date: "2024-08-16T19:00:00+00:00", home_id: 33, away_id: 36)
    {
      "fixture" => { "id" => id, "date" => date,
                     "status" => { "long" => "", "short" => status, "elapsed" => nil } },
      "league" => { "id" => 39, "name" => "Premier League", "season" => 2024 },
      "teams" => { "home" => { "id" => home_id, "name" => "Manchester United" },
                   "away" => { "id" => away_id, "name" => "Fulham" } },
      "goals" => { "home" => home_goals, "away" => away_goals },
    }
  end

  # Team mappings, as the mapping task would have created them.
  def map_teams!
    ExternalIdentifier.create!(provider: "api_football", external_id: "33", team: home)
    ExternalIdentifier.create!(provider: "api_football", external_id: "36", team: away)
  end

  def existing_match(status: "scheduled", home_score: nil, away_score: nil,
                     kickoff: Time.utc(2024, 8, 16, 19, 0))
    Match.create!(competition: competition, season: season, home_team: home,
                  away_team: away, kickoff_at: kickoff, status: status,
                  home_score: home_score, away_score: away_score)
  end

  describe "creating a new fixture" do
    before { map_teams! }

    it "creates the match" do
      result = reconciler.apply_fixture(adapter.normalize_fixture(payload), season: season)

      expect(result.kind).to eq(:created)
      expect(Match.count).to eq(1)
      expect(result.match.home_score).to eq(1)
      expect(result.match.status).to eq("completed")
    end

    it "records the provider identifier for the new match" do
      result = reconciler.apply_fixture(adapter.normalize_fixture(payload), season: season)

      mapping = ExternalIdentifier.find_by(provider: "api_football", external_id: "1208021")
      expect(mapping&.match_id).to eq(result.match.id)
    end

    it "records kickoff in UTC" do
      result = reconciler.apply_fixture(
        adapter.normalize_fixture(payload(date: "2024-08-16T21:00:00+02:00")), season: season,
      )

      expect(result.match.kickoff_at.utc.iso8601).to eq("2024-08-16T19:00:00Z")
    end
  end

  describe "idempotency" do
    before { map_teams! }

    it "skips an unchanged fixture on a second run" do
      reconciler.apply_fixture(adapter.normalize_fixture(payload), season: season)
      result = reconciler.apply_fixture(adapter.normalize_fixture(payload), season: season)

      expect(result.kind).to eq(:skipped)
      expect(Match.count).to eq(1)
    end

    it "does not duplicate a match that already exists without a provider mapping" do
      # A historical football-data.co.uk import created this fixture before
      # API-Football was introduced. Matching on teams+date is what prevents a
      # second copy of the same match.
      existing_match
      result = reconciler.apply_fixture(adapter.normalize_fixture(payload), season: season)

      expect(result.kind).to eq(:updated)
      expect(Match.count).to eq(1)
      # The existing match gains the provider mapping rather than being replaced.
      expect(ExternalIdentifier.find_by(provider: "api_football", external_id: "1208021")&.match_id).to eq(Match.first.id)
    end

    it "does not change an existing internal match id" do
      original = existing_match
      reconciler.apply_fixture(adapter.normalize_fixture(payload), season: season)

      expect(Match.first.id).to eq(original.id)
    end
  end

  describe "results" do
    before { map_teams! }

    it "promotes a scheduled match to completed" do
      match = existing_match
      result = reconciler.apply_fixture(adapter.normalize_fixture(payload), season: season)

      expect(result.kind).to eq(:updated)
      expect(match.reload.status).to eq("completed")
      expect([match.reload.home_score, match.away_score]).to eq([1, 0])
    end

    it "never overwrites an existing completed result with different data" do
      match = existing_match(status: "completed", home_score: 3, away_score: 1)
      result = reconciler.apply_fixture(adapter.normalize_fixture(payload), season: season)

      expect(result.kind).to eq(:conflict)
      expect(match.reload.home_score).to eq(3)
      expect(match.reload.away_score).to eq(1)
    end

    it "treats an existing completed result that agrees as unchanged" do
      existing_match(status: "completed", home_score: 1, away_score: 0)
      result = reconciler.apply_fixture(adapter.normalize_fixture(payload), season: season)

      expect(result.kind).to eq(:skipped)
    end

    it "never writes a live score into a match" do
      match = existing_match
      reconciler.apply_fixture(adapter.normalize_fixture(payload(status: "2H")), season: season)

      # The status advances to in_progress; the SCORE is what must never appear.
      expect(match.reload.status).to eq("in_progress")
      expect(match.home_score).to be_nil
      expect(match.away_score).to be_nil
    end

    it "does not downgrade a completed match when the provider reports it postponed" do
      match = existing_match(status: "completed", home_score: 2, away_score: 0)
      result = reconciler.apply_fixture(adapter.normalize_fixture(payload(status: "PST")), season: season)

      expect(result.kind).to eq(:conflict)
      expect(match.reload.status).to eq("completed")
      expect(match.reload.home_score).to eq(2)
    end
  end

  describe "reschedules" do
    before { map_teams! }

    it "updates the kickoff when the provider moves a fixture" do
      match = existing_match
      result = reconciler.apply_fixture(
        adapter.normalize_fixture(payload(status: "NS", date: "2024-08-16T20:30:00+00:00")),
        season: season,
      )

      expect(result.kind).to eq(:updated)
      expect(match.reload.kickoff_at.utc.iso8601).to eq("2024-08-16T20:30:00Z")
    end

    it "records a postponement" do
      match = existing_match
      reconciler.apply_fixture(adapter.normalize_fixture(payload(status: "PST")), season: season)

      expect(match.reload.status).to eq("postponed")
    end
  end

  describe "unmapped teams" do
    it "rejects a fixture whose teams have no mapping, without creating records" do
      result = reconciler.apply_fixture(adapter.normalize_fixture(payload), season: season)

      expect(result.kind).to eq(:rejected)
      expect(Match.count).to eq(0)
      # No teams are created either: an unmapped provider team is a mapping task,
      # not something an import may guess at.
      expect(Team.count).to eq(0)
    end

    it "never auto-creates a team from a provider name" do
      # Automatic creation is how duplicate teams appear: "Man Utd" and
      # "Manchester United" would become two canonical rows.
      before_count = Team.count
      reconciler.apply_fixture(adapter.normalize_fixture(payload), season: season)

      expect(Team.count).to eq(before_count)
    end
  end
end
