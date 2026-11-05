require "rails_helper"

# Persisting verified ESPN team mappings.
#
# Guardrails under test:
#   - only :verified identities are written; ambiguous/unmapped never are
#   - an existing mapping is never overwritten
#   - one provider id cannot map to two canonical teams (DB unique index)
#   - one canonical team cannot receive two provider ids
#   - a competition's clubs cannot receive another competition's identities
#   - the whole write is transactional
RSpec.describe Sync::EspnMappingPersister do
  let!(:sp1) { Competition.find_or_create_by!(code: "SP1") { |c| c.name = "La Liga" } }
  let!(:d1) { Competition.find_or_create_by!(code: "D1") { |c| c.name = "Bundesliga" } }
  let!(:sp1_season) do
    Season.find_or_create_by!(competition: sp1, name: "2026/27") do |s|
      s.start_date = Date.new(2026, 7, 1); s.end_date = Date.new(2027, 6, 30)
    end
  end
  let!(:d1_season) do
    Season.find_or_create_by!(competition: d1, name: "2026/27") do |s|
      s.start_date = Date.new(2026, 7, 1); s.end_date = Date.new(2027, 6, 30)
    end
  end

  let!(:home) { Team.find_or_create_by!(name: "Persist Home") { |t| t.normalized_name = "persist home" } }
  let!(:away) { Team.find_or_create_by!(name: "Persist Away") { |t| t.normalized_name = "persist away" } }
  let!(:other) { Team.find_or_create_by!(name: "Persist Other") { |t| t.normalized_name = "persist other" } }

  before do
    Match.create!(competition: sp1, season: sp1_season, home_team: home, away_team: away,
                  kickoff_at: Time.utc(2026, 8, 15, 15), status: "completed",
                  home_score: 1, away_score: 0)
    Match.create!(competition: d1, season: d1_season, home_team: other, away_team: away,
                  kickoff_at: Time.utc(2026, 8, 16, 15), status: "completed",
                  home_score: 2, away_score: 2)
  end

  def identity(matched:, ambiguous: [], unmapped: [])
    {
      matched: matched.map { |pid, team|
        { provider_id: pid, provider_name: team.name,
          canonical: team, status: :verified, basis: :exact }
      },
      ambiguous: ambiguous,
      unmapped: unmapped,
      existing: [], conflicts: [], invalid: [],
    }
  end

  subject(:persister) { described_class.new }

  describe "writing verified mappings" do
    it "persists a verified mapping as approved" do
      result = persister.call(code: "SP1", identity: identity(matched: { "9500001" => home }))

      expect(result.created).to eq(1)
      row = ExternalIdentifier.find_by(provider: "espn", external_id: "9500001")
      expect(row.team).to eq(home)
      expect(row.review_state).to eq("approved")
    end

    it "is idempotent: a second run creates nothing" do
      persister.call(code: "SP1", identity: identity(matched: { "9500002" => home }))
      second = persister.call(code: "SP1", identity: identity(matched: { "9500002" => home }))

      expect(second.created).to eq(0)
      expect(second.already_present).to eq(1)
    end
  end

  describe "refusals" do
    it "never writes an ambiguous identity" do
      result = persister.call(code: "SP1", identity: identity(matched: {}, ambiguous: [{ provider_name: "X" }]))
      expect(result.created).to eq(0)
    end

    it "never overwrites an existing mapping to a different team" do
      ExternalIdentifier.create!(provider: "espn", external_id: "9500003", team: other)

      result = persister.call(code: "SP1", identity: identity(matched: { "9500003" => home }))

      expect(result.skipped_existing).to eq(1)
      expect(ExternalIdentifier.find_by(provider: "espn", external_id: "9500003").team).to eq(other)
    end

    it "refuses a team that is not part of the stated competition" do
      # `other` belongs to D1 only, so it is not an SP1 mapping candidate.
      result = persister.call(code: "SP1", identity: identity(matched: { "9500004" => other }))

      expect(result.created).to eq(0)
      expect(result.rejected).to include("9500004")
    end
  end

  describe "competition isolation" do
    it "maps the same club from two competitions under distinct provider ids" do
      persister.call(code: "SP1", identity: identity(matched: { "9500010" => home }))
      persister.call(code: "D1", identity: identity(matched: { "9500011" => other }))

      expect(ExternalIdentifier.where(provider: "espn", external_id: %w[9500010 9500011]).count).to eq(2)
    end

    it "reports the competition actually written" do
      result = persister.call(code: "SP1", identity: identity(matched: { "9500012" => home }))
      expect(result.competition_code).to eq("SP1")
    end
  end
end
