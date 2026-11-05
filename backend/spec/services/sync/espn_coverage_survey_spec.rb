require 'rails_helper'

# Batch discovery + preview across every configured competition.
#
# ISOLATION IS THE POINT
# ----------------------
# One league failing (no season row, provider outage, ambiguous clubs) must not stop
# the others and must not leak into them. Each competition is processed in its own
# rescue, and its outcome is always reported — never silently skipped.
RSpec.describe Sync::EspnCoverageSurvey do
  let!(:sp1) { Competition.find_or_create_by!(code: "SP1") { |c| c.name = "La Liga" } }
  let!(:d1) { Competition.find_or_create_by!(code: "D1") { |c| c.name = "Bundesliga" } }
  let!(:sp1_season) { Season.find_or_create_by!(competition: sp1, name: "2026/27") { |s| s.start_date = Date.new(2026, 7, 1); s.end_date = Date.new(2027, 6, 30) } }
  # D1 deliberately has NO 2026/27 season, to prove isolation.

  let(:home) { Team.find_or_create_by!(name: "Survey Home") { |t| t.normalized_name = "survey home" } }
  let(:away) { Team.find_or_create_by!(name: "Survey Away") { |t| t.normalized_name = "survey away" } }

  before do
    Match.create!(competition: sp1, season: sp1_season, home_team: home, away_team: away,
                  kickoff_at: Time.utc(2026, 8, 20, 15), status: "completed",
                  home_score: 1, away_score: 1)
    ExternalIdentifier.create!(provider: "espn", external_id: "7700001", team: home)
    ExternalIdentifier.create!(provider: "espn", external_id: "7700002", team: away)
  end

  # A client double: identity + events without touching the network.
  def stub_client
    client = instance_double(Import::EspnClient)
    allow(client).to receive(:teams) do |league:|
      if league == "esp.1"
        [{ "team" => { "id" => "7700001", "displayName" => "Survey Home" } },
         { "team" => { "id" => "7700002", "displayName" => "Survey Away" } },
         { "team" => { "id" => "7700003", "displayName" => "Unknown Rovers" } }]
      else
        []
      end
    end
    allow(client).to receive(:scoreboard_dates) do |league:, from_date:, to_date:|
      events = if league == "esp.1"
                 [{
                   "id" => "9000001", "date" => "2026-11-20T20:00Z",
                   "season" => { "year" => 2026 },
                   "competitions" => [{
                     "status" => { "type" => { "name" => "STATUS_SCHEDULED", "state" => "pre", "completed" => false } },
                     "competitors" => [
                       { "homeAway" => "home", "score" => nil, "team" => { "id" => "7700001", "displayName" => "Survey Home" } },
                       { "homeAway" => "away", "score" => nil, "team" => { "id" => "7700002", "displayName" => "Survey Away" } }
                     ]
                   }]
                 }]
               else
                 []
               end
      Import::EspnClient::Result.new(events: events, provider_ok: true, days: {})
    end
    client
  end

  subject(:survey) { described_class.new(client: stub_client) }

  describe "isolation" do
    it "reports a competition with no season as missing, and still processes others" do
      results = survey.call(codes: %w[D1 SP1], season_name: "2026/27",
                            from_date: Date.new(2026, 11, 1), to_date: Date.new(2026, 11, 30))

      expect(results["D1"][:status]).to eq(:missing_season)
      expect(results["SP1"][:status]).to eq(:ok)
    end

    it "captures a provider failure for one competition without aborting the batch" do
      client = stub_client
      allow(client).to receive(:teams).with(league: "esp.1").and_raise(Import::EspnClient::TransientError, "boom")

      results = described_class.new(client: client).call(
        codes: %w[SP1], season_name: "2026/27",
        from_date: Date.new(2026, 11, 1), to_date: Date.new(2026, 11, 30)
      )

      expect(results["SP1"][:status]).to eq(:provider_error)
      expect(results["SP1"][:error]).to include("boom")
    end
  end

  describe "per-competition result" do
    it "reports identity counts and preview counts for a usable competition" do
      results = survey.call(codes: %w[SP1], season_name: "2026/27",
                            from_date: Date.new(2026, 11, 1), to_date: Date.new(2026, 11, 30))
      row = results["SP1"]

      expect(row[:canonical_clubs]).to eq(2)
      expect(row[:provider_teams]).to eq(3)
      # 7700001/7700002 are already mapped in the fixture, so they are reported as
      # existing rather than as new proposals; 7700003 has no canonical club.
      expect(row[:existing]).to eq(2)
      expect(row[:verified]).to eq(0)
      expect(row[:unmapped]).to eq(1)
      expect(row[:counts][:would_create]).to eq(1)
    end
  end

  describe "no writes" do
    it "leaves the database unchanged across a full survey" do
      before = [Match.count, ExternalIdentifier.count]

      survey.call(codes: %w[D1 SP1], season_name: "2026/27",
                  from_date: Date.new(2026, 11, 1), to_date: Date.new(2026, 11, 30))

      expect([Match.count, ExternalIdentifier.count]).to eq(before)
    end
  end
end
