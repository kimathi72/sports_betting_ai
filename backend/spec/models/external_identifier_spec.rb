require "rails_helper"

# An ExternalIdentifier maps a provider's own identifier for a football entity
# onto this platform's canonical record. Providers disagree about identifiers —
# one calls the Premier League "EPL", another "1" — so provider identity is kept
# out of the canonical tables and centralised here.
#
# DESIGN: explicit nullable foreign keys, not a Rails polymorphic type/id pair.
#
#   provider          text   the source's key, e.g. "football_data"
#   external_id       text   the identifier that source uses for the entity
#   competition_id    bigint nullable FK -> competitions
#   season_id         bigint nullable FK -> seasons
#   team_id           bigint nullable FK -> teams
#   match_id          bigint nullable FK -> matches
#
# Exactly one of the four target columns must be set. That is enforced by a
# PostgreSQL check constraint (`external_identifiers_single_target`), so a row
# cannot point at two entities, and by real foreign keys, so a row cannot point
# at an entity that does not exist. A conventional polymorphic association would
# give neither guarantee: its `*_id` column cannot carry a database foreign key
# and its `*_type` string can name any class. The cost of this design is four
# nullable columns and four partial unique indexes instead of one composite
# index; the benefit is genuine referential integrity. See docs/roadmap.md.
RSpec.describe ExternalIdentifier, type: :model do
  let(:competition) { Competition.create!(name: "Premier League") }
  let(:season) { Season.create!(competition: competition, name: "2024/25") }
  let(:team) { Team.create!(name: "Arsenal") }

  def build_identifier(**overrides)
    ExternalIdentifier.new(
      {
        provider: "football_data",
        external_id: "12345",
        team: team,
      }.merge(overrides)
    )
  end

  describe "valid mappings" do
    it "is valid mapping a team" do
      expect(build_identifier(team: team)).to be_valid
    end

    it "is valid mapping a competition" do
      expect(build_identifier(team: nil, competition: competition)).to be_valid
    end

    it "is valid mapping a season" do
      expect(build_identifier(team: nil, season: season)).to be_valid
    end

    it "is valid mapping a match" do
      match = Match.create!(
        competition: competition, season: season,
        home_team: team, away_team: Team.create!(name: "Chelsea"),
        kickoff_at: Time.utc(2024, 8, 17, 15, 0), status: "scheduled"
      )

      expect(build_identifier(team: nil, match: match)).to be_valid
    end

    it "persists and reloads the mapping" do
      identifier = build_identifier(team: team)
      identifier.save!

      expect(identifier.reload.team).to eq(team)
      expect(identifier.provider).to eq("football_data")
      expect(identifier.external_id).to eq("12345")
    end
  end

  describe "required attributes" do
    it "is invalid without a provider" do
      identifier = build_identifier(provider: nil)

      expect(identifier).not_to be_valid
      expect(identifier.errors[:provider]).to be_present
    end

    it "is invalid with a blank provider" do
      expect(build_identifier(provider: "   ")).not_to be_valid
    end

    it "is invalid without an external_id" do
      identifier = build_identifier(external_id: nil)

      expect(identifier).not_to be_valid
      expect(identifier.errors[:external_id]).to be_present
    end

    it "is invalid with a blank external_id" do
      expect(build_identifier(external_id: "   ")).not_to be_valid
    end
  end

  describe "exactly one target" do
    it "is invalid without any target" do
      identifier = build_identifier(team: nil)

      expect(identifier).not_to be_valid
      expect(identifier.errors[:base].join).to match(/target/i)
    end

    it "is invalid with more than one target" do
      identifier = build_identifier(team: team, competition: competition)

      expect(identifier).not_to be_valid
      expect(identifier.errors[:base].join).to match(/target/i)
    end
  end

  describe "uniqueness" do
    it "rejects a duplicate external_id for the same provider and entity type" do
      build_identifier(team: team).save!
      other_team = Team.create!(name: "Chelsea")

      expect(build_identifier(team: other_team)).not_to be_valid
    end

    it "allows the same external_id for a different provider" do
      build_identifier(team: team).save!
      other_team = Team.create!(name: "Chelsea")

      expect(
        build_identifier(team: other_team, provider: "other_source")
      ).to be_valid
    end

    it "allows the same external_id for a different entity type" do
      build_identifier(team: team).save!
      other_team = Team.create!(name: "Chelsea")
      other_team_match = Match.create!(
        competition: competition, season: season,
        home_team: team, away_team: other_team,
        kickoff_at: Time.utc(2024, 8, 18, 15, 0), status: "scheduled"
      )

      expect(
        build_identifier(team: nil, match: other_team_match)
      ).to be_valid
    end

    it "allows two providers to map the same canonical team" do
      build_identifier(team: team).save!

      expect(
        build_identifier(team: team, provider: "other_source")
      ).to be_valid
    end
  end

  describe "database constraints" do
    def insert_identifier(overrides = {})
      values = {
        provider: "'football_data'",
        external_id: "'12345'",
        competition_id: "NULL",
        season_id: "NULL",
        team_id: team.id,
        match_id: "NULL",
      }.merge(overrides)

      ExternalIdentifier.connection.execute(
        "INSERT INTO external_identifiers (provider, external_id, competition_id, " \
        "season_id, team_id, match_id, created_at, updated_at) VALUES (" \
        "#{values[:provider]}, #{values[:external_id]}, #{values[:competition_id]}, " \
        "#{values[:season_id]}, #{values[:team_id]}, #{values[:match_id]}, " \
        "CURRENT_TIMESTAMP, CURRENT_TIMESTAMP)"
      )
    end

    it "requires a provider at the database level" do
      expect {
        insert_identifier(provider: "NULL")
      }.to raise_error(ActiveRecord::StatementInvalid, /null/i)
    end

    it "requires an external_id at the database level" do
      expect {
        insert_identifier(external_id: "NULL")
      }.to raise_error(ActiveRecord::StatementInvalid, /null/i)
    end

    it "rejects a row with no target" do
      expect {
        insert_identifier(team_id: "NULL")
      }.to raise_error(ActiveRecord::StatementInvalid, /check/i)
    end

    it "rejects a row with more than one target" do
      expect {
        insert_identifier(team_id: team.id, competition_id: competition.id)
      }.to raise_error(ActiveRecord::StatementInvalid, /check/i)
    end

    it "enforces the foreign key to teams" do
      expect {
        insert_identifier(team_id: 999_999)
      }.to raise_error(ActiveRecord::InvalidForeignKey)
    end

    it "enforces the foreign key to competitions" do
      expect {
        insert_identifier(team_id: "NULL", competition_id: 999_999)
      }.to raise_error(ActiveRecord::InvalidForeignKey)
    end

    it "enforces the foreign key to seasons" do
      expect {
        insert_identifier(team_id: "NULL", season_id: 999_999)
      }.to raise_error(ActiveRecord::InvalidForeignKey)
    end

    it "enforces the foreign key to matches" do
      expect {
        insert_identifier(team_id: "NULL", match_id: 999_999)
      }.to raise_error(ActiveRecord::InvalidForeignKey)
    end

    it "rejects a duplicate external_id in the same provider and entity scope" do
      build_identifier(team: team).save!

      expect {
        insert_identifier
      }.to raise_error(ActiveRecord::StatementInvalid, /unique/i)
    end

    it "allows the same external_id for a different provider" do
      build_identifier(team: team).save!

      expect {
        insert_identifier(provider: "'other_source'")
      }.not_to raise_error
    end
  end
end
