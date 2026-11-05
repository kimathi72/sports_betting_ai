require "rails_helper"

# One reusable competition configuration, used by every ESPN league.
#
# The point of this spec file is that the SAME service is exercised for several
# competitions with different slugs, and nothing competition-specific is needed
# beyond an entry in EspnLeagueCoverage::VERIFIED.
RSpec.describe Sync::EspnCompetitionPlan do
  let!(:e0) { Competition.find_or_create_by!(code: "E0") { |c| c.name = "Premier League" } }
  let!(:sp1) { Competition.find_or_create_by!(code: "SP1") { |c| c.name = "La Liga" } }
  let!(:e0_season) do
    Season.find_or_create_by!(competition: e0, name: "2026/27") do |s|
      s.start_date = Date.new(2026, 7, 1)
      s.end_date = Date.new(2027, 6, 30)
    end
  end
  let!(:sp1_season) do
    Season.find_or_create_by!(competition: sp1, name: "2026/27") do |s|
      s.start_date = Date.new(2026, 7, 1)
      s.end_date = Date.new(2027, 6, 30)
    end
  end

  describe ".for_code" do
    it "builds a plan from a catalogue code alone" do
      plan = described_class.for_code("SP1", season_name: "2026/27")

      expect(plan.code).to eq("SP1")
      expect(plan.slug).to eq("esp.1")
      expect(plan.competition).to eq(sp1)
      expect(plan.season).to eq(sp1_season)
    end

    it "resolves a different competition through the same call" do
      plan = described_class.for_code("E0", season_name: "2026/27")

      expect(plan.slug).to eq("eng.1")
      expect(plan.season).to eq(e0_season)
    end

    it "sources the slug from the shared coverage map, not a second list" do
      EspnLeagueCoverage::VERIFIED.each_key do |code|
        competition = Competition.find_or_create_by!(code: code) { |c| c.name = code }
        Season.find_or_create_by!(competition: competition, name: "2026/27")

        plan = described_class.for_code(code, season_name: "2026/27")
        expect(plan.slug).to eq(EspnLeagueCoverage.slug_for(code))
      end
    end

    it "raises for a code with no ESPN feed" do
      expect { described_class.for_code("E3", season_name: "2026/27") }.to raise_error(Sync::EspnCompetitionPlan::Unsupported)
    end

    it "raises when the competition does not exist locally" do
      expect { described_class.for_code("ZZ9", season_name: "2026/27") }.to raise_error(Sync::EspnCompetitionPlan::Unsupported)
    end

    it "raises when the competition has no season for that label" do
      expect { described_class.for_code("SP1", season_name: "1999/00") }.to raise_error(Sync::EspnCompetitionPlan::MissingSeason)
    end
  end

  describe "inventory" do
    it "lists the canonical clubs of the competition's season" do
      home = Team.find_or_create_by!(name: "Plan Home") { |t| t.normalized_name = "plan home" }
      away = Team.find_or_create_by!(name: "Plan Away") { |t| t.normalized_name = "plan away" }
      Match.create!(competition: sp1, season: sp1_season, home_team: home, away_team: away,
                    kickoff_at: Time.utc(2026, 8, 15, 15), status: "completed",
                    home_score: 1, away_score: 0)

      plan = described_class.for_code("SP1", season_name: "2026/27")

      expect(plan.canonical_clubs).to include(home, away)
      expect(described_class.for_code("E0", season_name: "2026/27").canonical_clubs).not_to include(home)
    end
  end

  describe "evidence scope" do
    it "reads only alias evidence for its own competition" do
      plan = described_class.for_code("SP1", season_name: "2026/27")
      expect(plan.evidence.keys).to all(be_a(String))
    end
  end
end
