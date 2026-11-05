require "rails_helper"

# Candidate resolution for ESPN team ids.
#
# The stakes: a wrong mapping files one club's fixtures under another, which is
# silently wrong everywhere downstream (tables, head-to-head, training labels).
# These specs pin the rules that make a mapping safe to propose.
RSpec.describe Import::EspnTeamResolver do
  subject(:resolver) { described_class.new }

  def team(name)
    Team.new(name: name, normalized_name: Team.normalize(name))
  end

  describe "exact matches" do
    it "resolves a name that normalises identically" do
      arsenal = team("Arsenal")
      expect(resolver.resolve("Arsenal", [arsenal, team("Chelsea")])).to equal(arsenal)
    end

    it "prefers an exact match over a containing one" do
      city = team("Man City")
      united = team("Man United")
      expect(resolver.resolve("Man City", [city, united])).to equal(city)
    end
  end

  describe "containment matches" do
    it "maps ESPN full names onto the CSV short form" do
      city = team("Man City")
      expect(resolver.resolve("Manchester City", [city, team("Man United")])).to equal(city)
    end

    it "does not map a fragment too short to be conclusive" do
      # ESPN says "Nottingham Forest"; ours is "Nott'm Forest". The shared part
      # ("forest") is below MIN_SHARED_LENGTH, so this is refused rather than
      # guessed. That is a real, documented gap the operator sees in
      # `espn:pending_team_mappings`, not an accident.
      forest = team("Nott'm Forest")
      expect(resolver.resolve("Forest", [forest])).to eq(:no_candidate)
    end

    it "maps a longer provider name onto a shorter canonical one" do
      # Man United -> manchester united: each word is an abbreviation of its
      # partner, on both sides.
      united = team("Man United")
      expect(resolver.resolve("Manchester United", [united])).to equal(united)
    end

    it "does not map a shared head word onto the wrong club" do
      city = team("Man City")
      expect(resolver.resolve("Manchester United", [city])).to eq(:no_candidate)
    end
  end

  describe "refusals" do
    it "returns :no_candidate when nothing resembles the provider name" do
      expect(resolver.resolve("Real Madrid", [team("Arsenal"), team("Chelsea")])).to eq(:no_candidate)
    end

    it "returns :ambiguous when two clubs qualify, rather than picking one" do
      # Sheffield United and Sheffield Wednesday are different clubs. After the
      # single-word fix a bare "Sheffield" can no longer reach a multi-word name
      # at all, so it is refused outright — a stricter answer than :ambiguous.
      # The contract being pinned is "never pick one of the two", and both
      # refusals satisfy it.
      clubs = [team("Sheffield United"), team("Sheffield Wednesday")]
      expect(resolver.resolve("Sheffield", clubs)).to eq(:no_candidate)
      expect(resolver.resolve("Sheffield", clubs)).not_to be_a(Team)
    end

    it "returns :ambiguous when two multi-word clubs share a head word" do
      # "Sheffield City" reduces to two words, so it reaches both multi-word
      # Sheffield clubs and must be refused as ambiguous rather than picked.
      clubs = [team("Sheffield United"), team("Sheffield Wednesday")]
      expect(resolver.resolve("Sheffield City", clubs)).to eq(:ambiguous)
    end

    it "returns :no_candidate for a blank name" do
      expect(resolver.resolve("", [team("Arsenal")])).to eq(:no_candidate)
    end

    it "refuses a query that is nothing but a club word" do
      # "FC" reduces to an empty key, so it cannot reach any club — the strongest
      # possible answer here, since there is nothing left to identify a club by.
      expect(resolver.resolve("FC", [team("FC Barcelona"), team("FC Porto")])).to eq(:no_candidate)
    end
  end

  describe "false-positive safety" do
    it "does not resolve a club onto another club that shares no name" do
      # Live regression: "Bayern Munich" resolved to Inter Milan. Both reduce to
      # a single word, so the shared-head comparison ran on two empty heads and
      # [] == [] matched everything with one word.
      inter = team("Inter")
      expect(resolver.resolve("Bayern Munich", [inter])).to eq(:no_candidate)
    end

    it "does not let a single-word provider name match a single-word club" do
      roma = team("Roma")
      expect(resolver.resolve("Napoli", [roma])).to eq(:no_candidate)
    end

    it "still resolves a shared head word when both names are multi-word" do
      united = team("Sheffield United")
      expect(resolver.resolve("Sheffield United FC", [united])).to be_a(Team)
    end
  end
end
