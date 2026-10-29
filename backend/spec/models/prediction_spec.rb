require 'rails_helper'

# A stored 1X2 prediction for one match, produced by one model version.
#
# Design constraints this spec pins:
#   - probabilities are HOME/DRAW/AWAY for the fixture, never odds
#   - a prediction belongs to exactly one match and one model version
#   - a prediction may only be made for a fixture that has NOT been completed,
#     because a prediction after the result is leakage, not a prediction
#   - probabilities are a real distribution: each in [0,1] and summing to 1
#   - regenerating a prediction supersedes the old one; it never mutates history
RSpec.describe Prediction do
  let(:competition) { Competition.create!(name: 'Premier League', code: 'EPL') }
  let(:season) { Season.create!(competition: competition, name: '2026/27') }
  let(:home) { Team.create!(name: 'Arsenal') }
  let(:away) { Team.create!(name: 'Chelsea') }

  def build_match(status: 'scheduled', kickoff: Time.utc(2026, 8, 20, 15, 0), **extra)
    Match.create!(
      competition: competition, season: season, home_team: home, away_team: away,
      kickoff_at: kickoff, status: status,
      home_score: status == 'completed' ? 2 : nil,
      away_score: status == 'completed' ? 1 : nil,
      **extra
    )
  end

  def prediction(overrides = {})
    described_class.new(
      {
        match: build_match,
        model_version: 'v1',
        home_probability: 0.5,
        draw_probability: 0.3,
        away_probability: 0.2,
        generated_at: Time.utc(2026, 8, 19, 10, 0)
      }.merge(overrides)
    )
  end

  describe 'a valid prediction' do
    it 'saves with a full probability distribution' do
      record = prediction

      expect(record).to be_valid
      record.save!

      expect(record.reload.home_probability.to_f).to be_within(1e-9).of(0.5)
      expect(record.probabilities.values.sum).to be_within(1e-6).of(1.0)
    end

    it 'exposes the outcome with the highest probability' do
      record = prediction(home_probability: 0.2, draw_probability: 0.3, away_probability: 0.5)
      record.save!

      expect(record.most_likely_outcome).to eq('away')
    end

    it 'records when it was generated' do
      record = prediction
      record.save!

      expect(record.generated_at).to eq(Time.utc(2026, 8, 19, 10, 0))
    end
  end

  describe 'probability integrity' do
    it 'rejects probabilities that do not sum to one' do
      record = prediction(home_probability: 0.5, draw_probability: 0.5, away_probability: 0.5)

      expect(record).not_to be_valid
      expect(record.errors.full_messages.join(' ')).to match(/sum|total/i)
    end

    it 'rejects a negative probability' do
      expect(prediction(home_probability: -0.1)).not_to be_valid
    end

    it 'rejects a probability above one' do
      expect(prediction(home_probability: 1.5)).not_to be_valid
    end

    it 'rejects a missing probability' do
      expect(prediction(draw_probability: nil)).not_to be_valid
    end

    it 'is enforced by the database, not only the model' do
      record = prediction
      record.save!

      expect {
        ActiveRecord::Base.connection.execute(
          "UPDATE predictions SET home_probability = 0.99, draw_probability = 0.99 WHERE id = #{record.id}"
        )
      }.to raise_error(ActiveRecord::StatementInvalid)
    end
  end

  describe 'fixture rules' do
    it 'requires a match' do
      expect(prediction(match: nil)).not_to be_valid
    end

    it 'requires a model version' do
      expect(prediction(model_version: '')).not_to be_valid
    end

    it 'refuses to predict a match that has already been completed' do
      record = prediction(match: build_match(status: 'completed'))

      expect(record).not_to be_valid
      expect(record.errors.full_messages.join(' ')).to match(/completed|result/i)
    end

    it 'allows predicting a scheduled fixture' do
      expect(prediction(match: build_match(status: 'scheduled'))).to be_valid
    end

    it 'allows predicting a postponed fixture (it may still be played)' do
      expect(prediction(match: build_match(status: 'postponed'))).to be_valid
    end
  end

  describe 'generation metadata' do
    it 'stores the feature set used, so a prediction can be reproduced' do
      record = prediction(features: { 'home_form_5' => 0.6 })
      record.save!

      expect(record.reload.features).to eq('home_form_5' => 0.6)
    end

    it 'stores model metadata alongside the version' do
      record = prediction(model_metadata: { 'trained_at' => '2026-08-01T00:00:00Z', 'n_features' => 17 })
      record.save!

      expect(record.reload.model_metadata['n_features']).to eq(17)
    end

    it 'defaults features and metadata to an empty hash rather than null' do
      record = prediction
      record.save!

      expect(record.reload.features).to eq({})
      expect(record.reload.model_metadata).to eq({})
    end
  end

  describe 'superseding' do
    # One fixture, two generations: superseding is about the SAME match getting a
    # newer prediction, so the fixture must be shared across both records.
    let(:fixture) { build_match }

    it 'marks an earlier prediction as superseded when a newer one is stored' do
      old = prediction(match: fixture)
      old.save!

      newer = prediction(match: fixture, home_probability: 0.4, draw_probability: 0.4,
                         away_probability: 0.2, generated_at: Time.utc(2026, 8, 19, 12, 0))
      newer.save!

      expect(old.reload).to be_superseded
      expect(newer.reload).not_to be_superseded
    end

    it 'keeps the earlier prediction rather than deleting history' do
      old = prediction(match: fixture)
      old.save!
      prediction(match: fixture, generated_at: Time.utc(2026, 8, 19, 12, 0)).save!

      expect(described_class.where(match_id: fixture.id).count).to eq(2)
    end

    it 'exposes only the current prediction through a scope' do
      prediction(match: fixture).save!
      newer = prediction(match: fixture, generated_at: Time.utc(2026, 8, 19, 12, 0))
      newer.save!

      expect(described_class.current.to_a).to eq([newer])
    end
  end
end
