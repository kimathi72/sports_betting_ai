require 'rails_helper'

# The time-safety guarantee for feature generation.
#
# The ML service computes the 17-feature vector from a match plus its history.
# Rails' only job is to hand over history that is provably in the past, because a
# single future or same-kickoff result in that list leaks the outcome into the
# features and inflates every score the model reports.
#
# So this service answers exactly one question: "which completed matches had
# finished before this fixture kicked off?" It deliberately does NOT compute
# features — that would duplicate Kilo's `compute_match_features` and give the
# project two implementations that can silently disagree.
RSpec.describe Predictions::MatchHistory do
  let(:competition) { Competition.create!(name: 'Premier League', code: 'EPL') }
  let(:season) { Season.create!(competition: competition, name: '2024/25') }

  let(:arsenal) { Team.create!(name: 'Arsenal') }
  let(:chelsea) { Team.create!(name: 'Chelsea') }
  let(:everton) { Team.create!(name: 'Everton') }
  let(:spurs) { Team.create!(name: 'Spurs') }

  def fixture(kickoff:, home:, away:, status: 'completed', hs: 1, as: 0)
    Match.create!(
      competition: competition, season: season, home_team: home, away_team: away,
      kickoff_at: kickoff, status: status,
      home_score: status == 'completed' ? hs : nil,
      away_score: status == 'completed' ? as : nil
    )
  end

  let!(:target) { fixture(kickoff: Time.utc(2024, 9, 15, 15, 0), home: arsenal, away: chelsea,
                          status: 'scheduled') }

  let!(:before) { fixture(kickoff: Time.utc(2024, 9, 1, 15, 0), home: arsenal, away: everton, hs: 2) }
  let!(:also_before) { fixture(kickoff: Time.utc(2024, 9, 8, 15, 0), home: spurs, away: chelsea, hs: 0, as: 3) }

  # Must never appear: after kickoff, or at the same instant.
  let!(:after) { fixture(kickoff: Time.utc(2024, 9, 16, 15, 0), home: arsenal, away: spurs, hs: 9) }
  let!(:same_instant) { fixture(kickoff: Time.utc(2024, 9, 15, 15, 0), home: everton, away: spurs, hs: 9) }

  # Must never appear: not completed, even though it is in the past.
  let!(:unfinished_past) do
    fixture(kickoff: Time.utc(2024, 9, 2, 15, 0), home: chelsea, away: spurs, status: 'postponed')
  end

  subject(:history) { described_class.for(target) }

  describe 'the strict past-only rule' do
    it 'includes only matches that kicked off strictly before the fixture' do
      expect(history.map { |m| m['id'] }).to contain_exactly(before.id, also_before.id)
    end

    it 'excludes matches after the fixture' do
      expect(history.map { |m| m['id'] }).not_to include(after.id)
    end

    it 'excludes a match kicking off at the same instant' do
      # Same kickoff means the result was not known when the fixture started;
      # including it would leak a simultaneous result.
      expect(history.map { |m| m['id'] }).not_to include(same_instant.id)
    end

    it 'excludes unfinished matches even when they are in the past' do
      expect(history.map { |m| m['id'] }).not_to include(unfinished_past.id)
    end

    it 'excludes the target fixture itself' do
      expect(history.map { |m| m['id'] }).not_to include(target.id)
    end
  end

  describe 'ordering and shape' do
    it 'returns history oldest first, as the ML service expects' do
      expect(history.map { |m| m['id'] }).to eq([before.id, also_before.id])
    end

    it 'serialises only fields the ML service needs' do
      expect(history.first.keys).to contain_exactly(
        'id', 'kickoff_at', 'status', 'home_team_id', 'away_team_id', 'home_score', 'away_score'
      )
    end

    it 'emits kickoffs as UTC ISO 8601 strings' do
      expect(history.map { |m| m['kickoff_at'] })
        .to all(match(/\A\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z\z/))
    end

    it 'never emits a match without both scores' do
      expect(history).to all(satisfy { |m| m['home_score'].is_a?(Integer) && m['away_score'].is_a?(Integer) })
    end
  end

  describe 'relevance' do
    it 'excludes matches that do not involve either team' do
      # A fixture between two unrelated clubs tells the model nothing about this
      # match and only inflates the payload.
      unrelated = fixture(kickoff: Time.utc(2024, 9, 3, 15, 0),
                          home: Team.create!(name: 'Fulham'), away: Team.create!(name: 'Brentford'))

      expect(history.map { |m| m['id'] }).not_to include(unrelated.id)
    end

    it 'keeps only the most recent matches per team' do
      # Seed 10 earlier Arsenal matches; only the most recent 5 should survive.
      recent = 10.times.map do |i|
        fixture(kickoff: Time.utc(2024, 8, 1, 15, 0) + (i * 86_400), home: arsenal,
                away: Team.create!(name: "Opponent #{i}"))
      end

      ids = history.map { |m| m['id'] }
      expect(ids).to include(*recent.last(5).map(&:id))
      expect(ids).not_to include(recent.first.id)
    end

    it 'caps the total payload rather than returning every historic match' do
      expect(history.length).to be <= described_class::LIMIT
    end
  end

  describe 'edge cases' do
    it 'returns an empty array for a fixture with no prior matches' do
      first_ever = fixture(kickoff: Time.utc(2015, 8, 8, 15, 0), home: arsenal, away: chelsea,
                           status: 'scheduled')

      expect(described_class.for(first_ever)).to eq([])
    end

  end
end
