require "rails_helper"

# Reassigns Championship fixtures that were filed under the Premier League.
#
# WHAT THIS REPAIRS
# -----------------
# `espn:discover` once resolved the target season by NAME, so `eng.2` fixtures were
# written into E0's 2026/27 season. The affected rows are identified by PROVIDER
# EVIDENCE — the ESPN event id — not by database id range, kickoff date or club
# membership. All three of those were measured and all three are wrong:
#
#   * the id range 39676..39787 contains only 112 of the affected rows;
#   * dates fall inside the season window like any real fixture;
#   * promoted/relegated clubs appear in both divisions.
#
# The provider id prefix is the only discriminator that survives contact with the
# data: `40187xxxxxx` events are served by `eng.1`, `40188xxxxxx` by `eng.2`.
#
# These specs run against the TEST database only and build their own fixtures.
RSpec.describe DataRepair::ReassignEspnChampionshipFixtures do
  let!(:e0) { Competition.find_or_create_by!(code: "E0") { |c| c.name = "Premier League" } }
  let!(:e1) { Competition.find_or_create_by!(code: "E1") { |c| c.name = "Championship" } }
  let!(:e0_season) do
    Season.find_or_create_by!(competition: e0, name: "2026/27") do |s|
      s.start_date = Date.new(2026, 7, 1)
      s.end_date = Date.new(2027, 6, 30)
    end
  end
  let!(:e1_season) do
    Season.find_or_create_by!(competition: e1, name: "2026/27") do |s|
      s.start_date = Date.new(2026, 7, 1)
      s.end_date = Date.new(2027, 6, 30)
    end
  end

  let!(:home) { Team.find_or_create_by!(name: "Repair Home") { |t| t.normalized_name = "repair home" } }
  let!(:away) { Team.find_or_create_by!(name: "Repair Away") { |t| t.normalized_name = "repair away" } }

  # "Championship club" is defined by completed results in E1, so the test clubs
  # need that history for the scope rule to consider them eligible.
  before do
    seed = Match.create!(competition: e1, season: e1_season, home_team: home, away_team: away,
                         kickoff_at: Time.utc(2026, 8, 10, 15), status: "completed",
                         home_score: 1, away_score: 0)
    ExternalIdentifier.create!(provider: "football_data", external_id: "fd-seed-#{seed.id}", match: seed)
  end

  def champ_fixture(espn_id:, status: "scheduled", kickoff: Time.utc(2026, 11, 7, 15))
    match = Match.create!(competition: e0, season: e0_season, home_team: home, away_team: away,
                          kickoff_at: kickoff, status: status,
                          home_score: status == "completed" ? 2 : nil,
                          away_score: status == "completed" ? 1 : nil)
    ExternalIdentifier.create!(provider: "espn", external_id: espn_id, match: match)
    match
  end

  subject(:repair) { described_class.new }

  describe "scope selection" do
    it "selects ESPN eng.2 fixtures currently filed under E0" do
      champ = champ_fixture(espn_id: "401880001")

      expect(repair.affected_ids).to include(champ.id)
    end

    it "does not select eng.1 fixtures, which belong in E0" do
      premier = champ_fixture(espn_id: "401870001")

      expect(repair.affected_ids).not_to include(premier.id)
    end

    it "does not select rows with football-data provenance" do
      trusted = champ_fixture(espn_id: "401880002")
      ExternalIdentifier.create!(provider: "football_data", external_id: "fd-#{trusted.id}", match: trusted)

      expect(repair.affected_ids).not_to include(trusted.id)
    end

    it "is not disarmed by football-data TEAM mappings that have no match_id" do
      # Real defect found against the live database: 469 football_data rows carry
      # a NULL match_id because they are team mappings. `SELECT match_id` then
      # yields NULLs, and `id NOT IN (..., NULL)` is NULL for every row, so the
      # exclusion silently matched nothing and the repair selected ZERO rows.
      ExternalIdentifier.create!(provider: "football_data", external_id: "fd-team-1",
                                 team: home, match_id: nil)
      champ = champ_fixture(espn_id: "401880004")

      expect(repair.affected_ids).to include(champ.id)
    end

    it "does not select a fixture whose clubs have no Championship history" do
      # Championship clubs are those with COMPLETED results in competition E1. A
      # row whose clubs never played there is not evidence of a bled fixture, and
      # is left alone rather than swept up by a broad query.
      other_home = Team.create!(name: "Repair Stranger A", normalized_name: "repair stranger a")
      other_away = Team.create!(name: "Repair Stranger B", normalized_name: "repair stranger b")
      stranger = Match.create!(competition: e0, season: e0_season, home_team: other_home,
                               away_team: other_away, kickoff_at: Time.utc(2026, 11, 9, 15),
                               status: "scheduled")
      ExternalIdentifier.create!(provider: "espn", external_id: "401880003", match: stranger)

      expect(repair.affected_ids).not_to include(stranger.id)
    end
  end

  describe "guards" do
    it "aborts when the destination season belongs to another competition" do
      champ_fixture(espn_id: "401880010")
      repair.instance_variable_set(:@destination_season, e0_season)

      expect { repair.call }
        .to raise_error(DataRepair::ReassignEspnChampionshipFixtures::GuardFailed)
    end

    it "aborts when a selected row is not in the expected source season" do
      champ = champ_fixture(espn_id: "401880011")
      Match.where(id: champ.id).update_all(season_id: e1_season.id)

      # Pinning the count makes the drift explicit rather than silent: the row is
      # gone from the source scope, so the expected total no longer holds.
      expect { described_class.new(expected_count: 1).call }
        .to raise_error(DataRepair::ReassignEspnChampionshipFixtures::GuardFailed, /expected/)
    end

    it "refuses to run outside a non-production environment" do
      allow(Rails).to receive(:env).and_return(ActiveSupport::StringInquirer.new("production"))

      expect { repair.call }
        .to raise_error(DataRepair::ReassignEspnChampionshipFixtures::GuardFailed, /production/)
    end
  end

  describe "reassignment" do
    it "moves the rows to the destination competition without touching any other attribute" do
      champ = champ_fixture(espn_id: "401880020")
      before = champ.attributes.slice("home_team_id", "away_team_id", "kickoff_at", "status",
                                      "home_score", "away_score")

      repair.call
      champ.reload

      expect(champ.competition_id).to eq(repair.destination_competition.id)
      expect(champ.season_id).to eq(repair.destination_season.id)
      expect(champ.competition_id).not_to eq(e0.id)
      expect(champ.attributes.slice(*before.keys)).to eq(before)
    end

    it "leaves the ESPN identifier in place" do
      champ = champ_fixture(espn_id: "401880021")
      repair.call

      expect(ExternalIdentifier.find_by(provider: "espn", match_id: champ.id).external_id)
        .to eq("401880021")
    end

    it "does not modify unrelated matches" do
      premier = champ_fixture(espn_id: "401870020")
      repair.call

      premier.reload
      expect([premier.competition_id, premier.season_id]).to eq([e0.id, e0_season.id])
    end

    it "updates exactly the rows it selected" do
      champ_fixture(espn_id: "401880030")
      champ_fixture(espn_id: "401880031")

      expect(repair.call.updated).to eq(2)
    end
  end

  describe "reversibility" do
    it "restores every affected row to its original competition and season" do
      champ = champ_fixture(espn_id: "401880040")
      repair.call
      repair.rollback!(repair.last_repair_token)

      champ.reload
      expect([champ.competition_id, champ.season_id]).to eq([e0.id, e0_season.id])
    end
  end
end
