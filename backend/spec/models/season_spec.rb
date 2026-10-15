require "rails_helper"

# A Season is a period of competition within one Competition. The platform
# stores its own internal representation rather than whatever label a provider
# happens to use, because providers format season labels inconsistently
# ("2024/25", "2024-25", "2024").
#
# Internal representation: `name` is the human label (e.g. "2024/25") and is
# unique within its competition. `start_date` and `end_date` are optional but,
# when both are present, start_date must not be after end_date. That ordering
# rule is enforced in the database with a check constraint as well as in the
# model.
RSpec.describe Season, type: :model do
  let(:competition) { Competition.create!(name: "Premier League") }

  describe "validations" do
    it "is valid with a competition and a name" do
      expect(Season.new(competition: competition, name: "2024/25")).to be_valid
    end

    it "is invalid without a name" do
      season = Season.new(competition: competition, name: nil)

      expect(season).not_to be_valid
      expect(season.errors[:name]).to be_present
    end

    it "is invalid without a competition" do
      season = Season.new(name: "2024/25")

      expect(season).not_to be_valid
      expect(season.errors[:competition]).to be_present
    end

    it "rejects a duplicate name within the same competition" do
      Season.create!(competition: competition, name: "2024/25")

      expect(Season.new(competition: competition, name: "2024/25")).not_to be_valid
    end

    it "allows the same name in a different competition" do
      other = Competition.create!(name: "La Liga")
      Season.create!(competition: competition, name: "2024/25")

      expect(Season.new(competition: other, name: "2024/25")).to be_valid
    end

    it "is valid when only a start date is present" do
      expect(
        Season.new(competition: competition, name: "2024/25", start_date: Date.new(2024, 8, 1))
      ).to be_valid
    end

    it "is valid when start date equals end date" do
      date = Date.new(2024, 8, 1)

      expect(
        Season.new(competition: competition, name: "2024/25", start_date: date, end_date: date)
      ).to be_valid
    end

    it "is invalid when start date is after end date" do
      season = Season.new(
        competition: competition,
        name: "2024/25",
        start_date: Date.new(2025, 5, 1),
        end_date: Date.new(2024, 8, 1),
      )

      expect(season).not_to be_valid
      expect(season.errors[:start_date]).to be_present
    end
  end

  describe "associations" do
    it "belongs to a competition" do
      season = Season.create!(competition: competition, name: "2024/25")

      expect(season.competition).to eq(competition)
    end

    it "has many matches" do
      season = Season.create!(competition: competition, name: "2024/25")

      expect(season.matches).to eq([])
    end

    it "restricts deletion when matches exist" do
      season = Season.create!(competition: competition, name: "2024/25")
      home = Team.create!(name: "Arsenal")
      away = Team.create!(name: "Chelsea")
      Match.create!(
        competition: competition, season: season,
        home_team: home, away_team: away,
        kickoff_at: Time.utc(2024, 8, 17, 15, 0), status: "scheduled",
      )

      # `dependent: :restrict_with_error` refuses the delete without raising.
      expect(season.destroy).to be(false)
      expect(season).to be_persisted
    end
  end

  describe "database constraints" do
    it "enforces the foreign key to competitions" do
      expect {
        Season.connection.execute(
          "INSERT INTO seasons (competition_id, name, created_at, updated_at) " \
          "VALUES (999999, '2024/25', CURRENT_TIMESTAMP, CURRENT_TIMESTAMP)"
        )
      }.to raise_error(ActiveRecord::InvalidForeignKey)
    end

    it "enforces a unique index on competition and name" do
      Season.create!(competition: competition, name: "2024/25")

      expect {
        Season.connection.execute(
          "INSERT INTO seasons (competition_id, name, created_at, updated_at) " \
          "VALUES (#{competition.id}, '2024/25', CURRENT_TIMESTAMP, CURRENT_TIMESTAMP)"
        )
      }.to raise_error(ActiveRecord::StatementInvalid, /unique/i)
    end

    it "rejects an inverted date range at the database level" do
      expect {
        Season.connection.execute(
          "INSERT INTO seasons (competition_id, name, start_date, end_date, created_at, updated_at) " \
          "VALUES (#{competition.id}, '2024/25', DATE '2025-05-01', DATE '2024-08-01', " \
          "CURRENT_TIMESTAMP, CURRENT_TIMESTAMP)"
        )
      }.to raise_error(ActiveRecord::StatementInvalid, /check/i)
    end
  end
end
