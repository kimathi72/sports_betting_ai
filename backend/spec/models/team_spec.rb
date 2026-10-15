require 'rails_helper'

# A Team plays in matches, independently of any single competition or season.
#
# Identity policy: team names come from many sources and vary in punctuation,
# accents and spacing ("Man. City" vs "Manchester City"). The platform stores
# the source name verbatim in `name` and a deterministic, comparison-friendly
# projection in `normalized_name`.
#
# Uniqueness is enforced on `normalized_name`, which deliberately does *not*
# treat the raw display name as a universal identity: two sources spelling a
# team differently still collapse to one canonical row. Fuzzy matching and
# aliases are explicitly out of scope for this phase.
RSpec.describe Team, type: :model do
  describe 'validations' do
    it 'is valid with a name' do
      expect(Team.new(name: 'Arsenal')).to be_valid
    end

    it 'is invalid without a name' do
      team = Team.new(name: nil)

      expect(team).not_to be_valid
      expect(team.errors[:name]).to be_present
    end

    it 'rejects a blank name' do
      expect(Team.new(name: '   ')).not_to be_valid
    end

    it 'rejects a duplicate normalized name' do
      Team.create!(name: 'Arsenal')

      expect(Team.new(name: 'Arsenal')).not_to be_valid
    end

    it 'accepts legitimate punctuation and accents' do
      expect(Team.new(name: "Brighton & Hove Albion")).to be_valid
      expect(Team.new(name: "AS Saint-Étienne")).to be_valid
      expect(Team.new(name: "1. FC Köln")).to be_valid
    end

    it 'is valid without a country' do
      expect(Team.new(name: 'Arsenal')).to be_valid
    end
  end

  describe 'normalization' do
    it 'derives a normalized name from the display name' do
      expect(Team.new(name: 'Arsenal').normalized_name).to eq('arsenal')
    end

    it 'strips surrounding whitespace' do
      expect(Team.new(name: '  Arsenal  ').normalized_name).to eq('arsenal')
    end

    it 'collapses internal whitespace' do
      expect(Team.new(name: 'Manchester   City').normalized_name).to eq('manchester city')
    end

    it 'folds diacritics to their base letters' do
      expect(Team.new(name: 'AS Saint-Étienne').normalized_name).to eq('as saint-etienne')
    end

    it 'downcases' do
      expect(Team.new(name: 'ARSENAL').normalized_name).to eq('arsenal')
    end

    it 'is deterministic and idempotent' do
      team = Team.new(name: 'Manchester City')

      expect(team.normalized_name).to eq(team.normalized_name)
    end

    it 'treats names differing only by case as the same team' do
      Team.create!(name: 'Arsenal')

      expect(Team.new(name: 'arsenal')).not_to be_valid
    end

    it 'treats names differing only by surrounding whitespace as the same team' do
      Team.create!(name: 'Arsenal')

      expect(Team.new(name: ' Arsenal ')).not_to be_valid
    end

    it 'keeps the original display name' do
      team = Team.create!(name: 'AS Saint-Étienne')

      expect(team.reload.name).to eq('AS Saint-Étienne')
    end
  end

  describe 'associations' do
    it 'has many home matches' do
      expect(Team.new(name: 'Arsenal').home_matches).to eq([])
    end

    it 'has many away matches' do
      expect(Team.new(name: 'Arsenal').away_matches).to eq([])
    end
  end

  describe 'database constraints' do
    # ActiveRecord's `insert` compiles to `ON CONFLICT DO NOTHING`, so it
    # cannot prove the unique index exists. Raw SQL bypasses that safety and
    # surfaces the real PostgreSQL violation, which is what we want to pin.
    it 'enforces a unique index on normalized_name' do
      Team.create!(name: 'Arsenal')

      expect {
        Team.connection.execute(
          "INSERT INTO teams (name, normalized_name, created_at, updated_at) " \
          "VALUES ('Arsenal FC', 'arsenal', CURRENT_TIMESTAMP, CURRENT_TIMESTAMP)"
        )
      }.to raise_error(ActiveRecord::StatementInvalid, /unique/i)
    end

    it 'requires a name at the database level' do
      expect {
        Team.connection.execute(
          "INSERT INTO teams (name, normalized_name, created_at, updated_at) " \
          "VALUES (NULL, 'x', CURRENT_TIMESTAMP, CURRENT_TIMESTAMP)"
        )
      }.to raise_error(ActiveRecord::StatementInvalid, /null/i)
    end
  end
end
