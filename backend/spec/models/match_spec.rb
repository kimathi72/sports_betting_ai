require "rails_helper"

# A Match is a fixture and, once played, its final result. It is the anchor for
# features, predictions and evaluation later in the project, so its integrity
# rules are the most important in this phase.
#
# Statuses are a closed set: scheduled, postponed, cancelled, in_progress,
# completed. Arbitrary strings are rejected by both the model and a PostgreSQL
# check constraint.
#
# Score rules:
#   - scores are non-negative integers when present
#   - home and away scores are either both present or both absent
#   - a completed match must have both scores
#   - a match that has not completed must not be required to have scores
RSpec.describe Match, type: :model do
  let(:competition) { Competition.create!(name: "Premier League") }
  let(:season) { Season.create!(competition: competition, name: "2024/25") }
  let(:home_team) { Team.create!(name: "Arsenal") }
  let(:away_team) { Team.create!(name: "Chelsea") }

  def build_match(**overrides)
    Match.new(
      {
        competition: competition,
        season: season,
        home_team: home_team,
        away_team: away_team,
        kickoff_at: Time.utc(2024, 8, 17, 15, 0),
        status: "scheduled",
      }.merge(overrides)
    )
  end

  describe "a scheduled fixture" do
    it "is valid without scores" do
      expect(build_match).to be_valid
    end

    it "persists with null scores" do
      match = build_match
      match.save!

      expect(match.reload.home_score).to be_nil
      expect(match.reload.away_score).to be_nil
    end
  end

  describe "a completed match" do
    it "is valid with both scores" do
      expect(build_match(status: "completed", home_score: 2, away_score: 1)).to be_valid
    end

    it "is invalid without scores" do
      match = build_match(status: "completed")

      expect(match).not_to be_valid
      expect(match.errors[:base].join).to match(/score/i)
    end

    it "is invalid with only a home score" do
      expect(build_match(status: "completed", home_score: 2)).not_to be_valid
    end

    it "is invalid with only an away score" do
      expect(build_match(status: "completed", away_score: 1)).not_to be_valid
    end
  end

  describe "team rules" do
    it "is invalid when both teams are the same" do
      match = build_match(away_team: home_team)

      expect(match).not_to be_valid
      expect(match.errors[:away_team]).to be_present
    end
  end

  describe "score validity" do
    it "is invalid with a negative home score" do
      expect(build_match(home_score: -1, away_score: 0)).not_to be_valid
    end

    it "is invalid with a negative away score" do
      expect(build_match(home_score: 0, away_score: -1)).not_to be_valid
    end

    it "is valid with a 0-0 score" do
      expect(build_match(status: "completed", home_score: 0, away_score: 0)).to be_valid
    end

    it "is invalid with only one score present" do
      expect(build_match(home_score: 1)).not_to be_valid
    end
  end

  describe "status" do
    Match::STATUSES.each do |status|
      it "accepts the #{status} status" do
        overrides = { status: status }
        overrides.merge!(home_score: 1, away_score: 0) if status == "completed"

        expect(build_match(**overrides)).to be_valid
      end
    end

    it "rejects an unsupported status" do
      match = build_match(status: "abandoned")

      expect(match).not_to be_valid
      expect(match.errors[:status]).to be_present
    end

    it "rejects a nil status" do
      expect(build_match(status: nil)).not_to be_valid
    end
  end

  describe "a postponed fixture" do
    it "is valid without scores" do
      expect(build_match(status: "postponed")).to be_valid
    end
  end

  describe "a cancelled fixture" do
    it "is valid without scores" do
      expect(build_match(status: "cancelled")).to be_valid
    end
  end

  describe "kickoff" do
    it "is invalid without a kickoff time" do
      match = build_match(kickoff_at: nil)

      expect(match).not_to be_valid
      expect(match.errors[:kickoff_at]).to be_present
    end
  end

  describe "relationships" do
    it "is invalid without a competition" do
      expect(build_match(competition: nil)).not_to be_valid
    end

    it "is invalid without a season" do
      expect(build_match(season: nil)).not_to be_valid
    end

    it "is invalid without a home team" do
      expect(build_match(home_team: nil)).not_to be_valid
    end

    it "is invalid without an away team" do
      expect(build_match(away_team: nil)).not_to be_valid
    end

    it "belongs to its competition, season and teams" do
      match = build_match
      match.save!

      expect(match.competition).to eq(competition)
      expect(match.season).to eq(season)
      expect(match.home_team).to eq(home_team)
      expect(match.away_team).to eq(away_team)
    end
  end

  describe "competition and season consistency" do
    it "is invalid when the season belongs to a different competition" do
      other_competition = Competition.create!(name: "La Liga")
      other_season = Season.create!(competition: other_competition, name: "2024/25")

      match = build_match(season: other_season)

      expect(match).not_to be_valid
      expect(match.errors[:season]).to be_present
    end
  end

  describe "database constraints" do
    def insert_match(overrides = {})
      values = {
        competition_id: competition.id,
        season_id: season.id,
        home_team_id: home_team.id,
        away_team_id: away_team.id,
        kickoff_at: "'2024-08-17 15:00:00'",
        status: "'scheduled'",
        home_score: "NULL",
        away_score: "NULL",
      }.merge(overrides)

      Match.connection.execute(
        "INSERT INTO matches (competition_id, season_id, home_team_id, away_team_id, " \
        "kickoff_at, status, home_score, away_score, created_at, updated_at) VALUES (" \
        "#{values[:competition_id]}, #{values[:season_id]}, #{values[:home_team_id]}, " \
        "#{values[:away_team_id]}, #{values[:kickoff_at]}, #{values[:status]}, " \
        "#{values[:home_score]}, #{values[:away_score]}, CURRENT_TIMESTAMP, CURRENT_TIMESTAMP)"
      )
    end

    it "rejects a match where both teams are identical" do
      expect {
        insert_match(away_team_id: home_team.id)
      }.to raise_error(ActiveRecord::StatementInvalid, /check/i)
    end

    it "rejects a negative score" do
      expect {
        insert_match(home_score: "-1", away_score: "0")
      }.to raise_error(ActiveRecord::StatementInvalid, /check/i)
    end

    it "rejects only one score being present" do
      expect {
        insert_match(home_score: "2")
      }.to raise_error(ActiveRecord::StatementInvalid, /check/i)
    end

    it "rejects a completed match without scores" do
      expect {
        insert_match(status: "'completed'")
      }.to raise_error(ActiveRecord::StatementInvalid, /check/i)
    end

    it "rejects an unsupported status" do
      expect {
        insert_match(status: "'abandoned'")
      }.to raise_error(ActiveRecord::StatementInvalid, /check/i)
    end

    it "accepts a valid scheduled fixture without scores" do
      expect { insert_match }.not_to raise_error
    end

    it "accepts a valid completed match with scores" do
      expect {
        insert_match(status: "'completed'", home_score: "3", away_score: "1")
      }.not_to raise_error
    end

    it "enforces the foreign key to competitions" do
      expect {
        insert_match(competition_id: 999_999)
      }.to raise_error(ActiveRecord::InvalidForeignKey)
    end

    it "enforces the foreign key to seasons" do
      expect {
        insert_match(season_id: 999_999)
      }.to raise_error(ActiveRecord::InvalidForeignKey)
    end

    it "enforces the foreign key to home teams" do
      expect {
        insert_match(home_team_id: 999_999)
      }.to raise_error(ActiveRecord::InvalidForeignKey)
    end

    it "enforces the foreign key to away teams" do
      expect {
        insert_match(away_team_id: 999_999)
      }.to raise_error(ActiveRecord::InvalidForeignKey)
    end
  end
end
