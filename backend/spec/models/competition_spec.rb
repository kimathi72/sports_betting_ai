require 'rails_helper'

# A Competition is the top of the football hierarchy: seasons and matches hang
# off it. The English Premier League is the first competition the platform
# will ingest.
#
# Identity policy: `name` is required and unique. `code` is an optional short
# identifier (e.g. "EPL") that must be unique when present, but is deliberately
# nullable because not every source supplies one. `country` is optional because
# some sources omit it.
RSpec.describe Competition, type: :model do
  describe 'validations' do
    it 'is valid with a name' do
      expect(Competition.new(name: 'Premier League')).to be_valid
    end

    it 'is invalid without a name' do
      competition = Competition.new(name: nil)

      expect(competition).not_to be_valid
      expect(competition.errors[:name]).to be_present
    end

    it 'rejects a blank name' do
      expect(Competition.new(name: '   ')).not_to be_valid
    end

    it 'rejects a duplicate name' do
      Competition.create!(name: 'Premier League')

      expect(Competition.new(name: 'Premier League')).not_to be_valid
    end

    it 'is valid without a code and without a country' do
      expect(Competition.new(name: 'Premier League')).to be_valid
    end

    it 'is valid with a code and country' do
      expect(
        Competition.new(name: 'Premier League', code: 'EPL', country: 'England')
      ).to be_valid
    end

    it 'rejects a duplicate code' do
      Competition.create!(name: 'Premier League', code: 'EPL')

      expect(Competition.new(name: 'Other League', code: 'EPL')).not_to be_valid
    end

    it 'allows multiple competitions without a code' do
      Competition.create!(name: 'Premier League')
      Competition.create!(name: 'La Liga')

      expect(Competition.count).to eq(2)
    end
  end

  describe 'associations' do
    it 'has many seasons' do
      competition = Competition.create!(name: 'Premier League')

      expect(competition.seasons).to eq([])
    end

    it 'has many matches' do
      competition = Competition.create!(name: 'Premier League')

      expect(competition.matches).to eq([])
    end

    it 'restricts deletion when seasons exist' do
      # `dependent: :restrict_with_error` refuses the delete, keeps the record
      # and records an error; it does not raise.
      competition = Competition.create!(name: 'Premier League')
      Season.create!(competition: competition, name: '2024/25')

      expect(competition.destroy).to be(false)
      expect(competition).to be_persisted
      expect(competition.errors[:base]).to be_present
    end
  end

  describe 'database constraints' do
    it 'enforces a unique index on name' do
      Competition.create!(name: 'Premier League')

      expect {
        Competition.connection.execute(
          "INSERT INTO competitions (name, created_at, updated_at) " \
          "VALUES ('Premier League', CURRENT_TIMESTAMP, CURRENT_TIMESTAMP)"
        )
      }.to raise_error(ActiveRecord::StatementInvalid, /unique/i)
    end

    it 'enforces a unique index on code' do
      Competition.create!(name: 'Premier League', code: 'EPL')

      expect {
        Competition.connection.execute(
          "INSERT INTO competitions (name, code, created_at, updated_at) " \
          "VALUES ('Other', 'EPL', CURRENT_TIMESTAMP, CURRENT_TIMESTAMP)"
        )
      }.to raise_error(ActiveRecord::StatementInvalid, /unique/i)
    end

    it 'requires a name at the database level' do
      expect {
        Competition.connection.execute(
          "INSERT INTO competitions (name, created_at, updated_at) " \
          "VALUES (NULL, CURRENT_TIMESTAMP, CURRENT_TIMESTAMP)"
        )
      }.to raise_error(ActiveRecord::StatementInvalid, /null/i)
    end
  end
end
