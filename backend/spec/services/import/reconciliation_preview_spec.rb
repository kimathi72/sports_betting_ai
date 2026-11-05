require "rails_helper"

# Read-only reconciliation preview.
#
# THE REQUIREMENT
# ---------------
# Preview and import must make the SAME decisions. A preview that reimplements the
# matching rules is worse than none: it reports a clean result and then the import
# behaves differently. So this class delegates to the real
# Import::ApiFootballReconciler for identity, and never calls its write methods.
#
# PROVING ZERO WRITES
# -------------------
# The specs below assert counts do not move, AND stub every write entry point to
# raise. A silent write that happened to leave a count unchanged (an update) would
# still fail loudly.
RSpec.describe Import::ReconciliationPreview do
  let!(:competition) { Competition.find_or_create_by!(code: "SPX") { |c| c.name = "Preview League" } }
  let!(:season) do
    Season.find_or_create_by!(competition: competition, name: "2031/32") do |s|
      s.start_date = Date.new(2031, 7, 1)
      s.end_date = Date.new(2032, 6, 30)
    end
  end
  let!(:home) { Team.find_or_create_by!(name: "Preview Home") { |t| t.normalized_name = "preview home" } }
  let!(:away) { Team.find_or_create_by!(name: "Preview Away") { |t| t.normalized_name = "preview away" } }

  before do
    ExternalIdentifier.create!(provider: "espn", external_id: "7000001", team: home)
    ExternalIdentifier.create!(provider: "espn", external_id: "7000002", team: away)
  end

  def row(key:, home_id: "7000001", away_id: "7000002", kickoff: Time.utc(2031, 11, 8, 15),
          status: "scheduled", home_score: nil, away_score: nil)
    Import::ApiFootballAdapter::FixtureRow.new(
      provider: "espn", provider_key: key, status: status, kickoff_at: kickoff,
      home_score: home_score, away_score: away_score,
      home_provider_team_id: home_id, away_provider_team_id: away_id,
      home_team_name: "Home", away_team_name: "Away",
      provider_league_id: nil, provider_season_year: "2031", provider_league_name: nil,
    )
  end

  subject(:preview) { described_class.new(reconciler: Import::ApiFootballReconciler.new) }

  describe "counts" do
    it "counts a new fixture without creating it" do
      result = preview.call([row(key: "8000001")], season: season)

      expect(result.counts[:would_create]).to eq(1)
      expect(Match.count).to eq(0)
    end

    it "counts an existing fixture as a skip" do
      Match.create!(competition: competition, season: season, home_team: home, away_team: away,
                    kickoff_at: Time.utc(2031, 11, 8, 15), status: "scheduled")

      result = preview.call([row(key: "8000002")], season: season)

      expect(result.counts[:existing]).to eq(1)
      expect(result.counts[:would_create]).to eq(0)
      expect(Match.count).to eq(1)
    end

    it "counts rows with an unmapped team as unresolved" do
      # A row where NEITHER club resolves is fully unresolved; one where only the
      # home club is missing is partially resolved. The two are reported separately
      # because the fix differs (map a club vs investigate the payload).
      neither = preview.call([row(key: "8000003", home_id: "9999999", away_id: "9999998")], season: season)
      expect(neither.counts[:unresolved]).to eq(1)
      expect(neither.counts[:would_create]).to eq(0)

      partial = preview.call([row(key: "8000006", home_id: "9999999")], season: season)
      expect(partial.counts[:part_resolved]).to eq(1)
      expect(partial.counts[:would_create]).to eq(0)
    end

    it "counts a row with no usable kickoff as invalid" do
      result = preview.call([row(key: "8000004", kickoff: nil)], season: season)

      expect(result.counts[:invalid]).to eq(1)
      expect(result.counts[:would_create]).to eq(0)
    end

    it "records postponed fixtures without treating them as ordinary scheduled" do
      result = preview.call([row(key: "8000005", status: "postponed")], season: season)

      expect(result.counts[:would_create]).to eq(1)
      expect(result.rows.first[:status]).to eq("postponed")
    end
  end

  describe "proposed (not yet persisted) mappings" do
    it "evaluates a mapping supplied in memory without writing it" do
      # THE BUG THIS PINS: the preview resolved teams only from the database, so a
      # dry run of a proposed mapping set reported "0 resolved" and looked as if
      # the proposal was worthless. The index makes the preview honest.
      identifiers_before = ExternalIdentifier.count
      city = Team.create!(name: "Preview City", normalized_name: "preview city")
      town = Team.create!(name: "Preview Town", normalized_name: "preview town")

      indexed = described_class.new(
        team_index: { "8800001" => city, "8800002" => town }
      ).call([row(key: "8000020", home_id: "8800001", away_id: "8800002")], season: season)

      expect(indexed.counts[:resolved]).to eq(1)
      expect(indexed.counts[:would_create]).to eq(1)
      expect(ExternalIdentifier.count).to eq(identifiers_before)
    end
  end

  describe "no writes" do
    it "does not change any count" do
      matches_before = Match.count
      identifiers_before = ExternalIdentifier.count

      result = preview.call([row(key: "8000010")], season: season)
      expect(result.counts[:would_create]).to eq(1)

      expect(Match.count).to eq(matches_before)
      expect(ExternalIdentifier.count).to eq(identifiers_before)
    end

    it "raises if any persistence method is reached" do
      [Match, ExternalIdentifier].each do |klass|
        allow(klass).to receive(:create!).and_raise("write attempted on #{klass}")
        allow(klass).to receive(:find_or_create_by!).and_raise("write attempted on #{klass}")
      end

      expect { preview.call([row(key: "8000011")], season: season) }.not_to raise_error
    end
  end
end
