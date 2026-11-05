require 'rails_helper'

# Provider identity resolution for an arbitrary ESPN competition.
#
# The limitation being removed
# ----------------------------
# Every ESPN mapping attempt so far was per-league: a human read the roster, wrote
# a one-off script, and hand-checked 20 names. Nine competitions share the same
# shape, so the fix is a resolver driven by configuration — the ESPN roster plus the
# canonical club list — not nine copies of the same script.
#
# Identity is never decided by name similarity alone. A candidate must pass one of
# an ordered ladder of *lexical* rules (exact, word-order, abbreviation, head-word),
# and any rule that yields more than one candidate is reported as ambiguous rather
# than picked. Ephemeral knowledge (an alias such as "Ath Bilbao" = "Athletic Club")
# is supplied as evidence by the caller and must carry a stated basis.
RSpec.describe Import::EspnTeamIdentity do
  def team(name)
    Team.new(name: name, normalized_name: Team.normalize(name))
  end

  def espn(id, name)
    { "id" => id.to_s, "displayName" => name }
  end

  describe "exact identity" do
    it "maps a name that normalises identically" do
      arsenal = team("Arsenal")
      result = described_class.new(canonical: [arsenal], provider_teams: [espn(1, "Arsenal")]).call

      expect(result[:matched].first).to include(canonical: arsenal, status: :verified, basis: :exact)
    end
  end

  describe "verified alias" do
    it "maps an alias only when the caller supplies evidence" do
      bilbao = team("Ath Bilbao")
      evidence = { "Athletic Club" => { canonical: "Ath Bilbao", basis: "EspnDisplayAlias" } }

      result = described_class.new(
        canonical: [bilbao], provider_teams: [espn(93, "Athletic Club")], evidence: evidence
      ).call

      expect(result[:matched].first).to include(status: :verified, basis: :evidence)
    end

    it "does not map an unreferenced name just because it is lexically close" do
      bilbao = team("Ath Bilbao")

      result = described_class.new(
        canonical: [bilbao], provider_teams: [espn(93, "Athletic Club")]
      ).call

      expect(result[:matched]).to be_empty
      expect(result[:unmapped].map { |u| u[:provider_name] }).to include("Athletic Club")
    end
  end

  describe "ambiguity" do
    it "reports two clubs sharing a head word as ambiguous, not matched" do
      clubs = [team("Sheffield United"), team("Sheffield Wednesday")]
      result = described_class.new(
        canonical: clubs, provider_teams: [espn(9, "Sheffield City")]
      ).call

      expect(result[:ambiguous].size).to eq(1)
      expect(result[:matched]).to be_empty
    end

    it "never assigns one provider id to two canonical clubs" do
      clubs = [team("Real Madrid"), team("Atletico Madrid")]
      result = described_class.new(
        canonical: clubs, provider_teams: [espn(86, "Real Madrid"), espn(86, "Real Madrid Derbi")]
      ).call

      canonical_ids = result[:matched].map { |m| m[:canonical].object_id }
      expect(canonical_ids).to eq(canonical_ids.uniq)
    end
  end

  describe "conflicts" do
    it "reports an existing mapping that disagrees with the discovered identity" do
      club = team("Sevilla")
      club.id = 501

      existing = { "243" => 999 } # provider id already mapped to a DIFFERENT team
      result = described_class.new(
        canonical: [club], provider_teams: [espn(243, "Sevilla")], existing_mappings: existing
      ).call

      expect(result[:conflicts].size).to eq(1)
      expect(result[:matched]).to be_empty
    end

    it "reports an already-correct mapping as existing, not as a new proposal" do
      club = team("Sevilla")
      club.id = 501

      result = described_class.new(
        canonical: [club], provider_teams: [espn(243, "Sevilla")], existing_mappings: { "243" => 501 }
      ).call

      expect(result[:existing].size).to eq(1)
      expect(result[:matched]).to be_empty
    end
  end

  describe "cross-competition safety" do
    it "does not map a provider team to a canonical club outside the supplied inventory" do
      # The canonical list IS the competition boundary: a club from another league
      # is not a candidate simply because its name matches.
      sevilla = team("Sevilla")

      result = described_class.new(
        canonical: [sevilla], provider_teams: [espn(83, "Barcelona")]
      ).call

      expect(result[:matched]).to be_empty
      expect(result[:unmapped].map { |u| u[:provider_id] }).to include("83")
    end
  end

  describe "provider ids" do
    it "ignores provider teams without a usable id" do
      result = described_class.new(
        canonical: [team("Sevilla")], provider_teams: [{ "displayName" => "Sevilla" }]
      ).call

      expect(result[:invalid]).to include("Sevilla")
    end
  end
end
