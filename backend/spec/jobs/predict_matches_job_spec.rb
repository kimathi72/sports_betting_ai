require 'rails_helper'

# Generates predictions for upcoming fixtures in the background.
#
# WHY QUEUED, NOT SYNCHRONOUS. A prediction call depends on the ML service being
# up and can take seconds per match. Doing it inside a GET would tie a read
# request to a second service and let a client trigger unbounded model work by
# refreshing. A job keeps the API read-only and fast, and makes failures visible
# as failed work instead of a hung request.
#
# The job never predicts a completed match: that would be hindsight and would
# contaminate evaluation.
RSpec.describe PredictMatchesJob do
  let(:competition) { Competition.create!(name: 'Premier League', code: 'EPL') }
  let(:season) { Season.create!(competition: competition, name: '2026/27') }
  let(:home) { Team.create!(name: 'Arsenal') }
  let(:away) { Team.create!(name: 'Chelsea') }

  def build_fixture(kickoff: Time.utc(2026, 8, 20, 15, 0), status: 'scheduled')
    Match.create!(competition: competition, season: season, home_team: home, away_team: away,
                  kickoff_at: kickoff, status: status,
                  home_score: status == 'completed' ? 2 : nil,
                  away_score: status == 'completed' ? 1 : nil)
  end

  describe 'the job contract' do
    it 'inherits from ApplicationJob' do
      expect(described_class.ancestors).to include(ApplicationJob)
    end

    it 'runs on its own queue so imports are not starved' do
      expect(described_class.new.queue_name).to eq('predictions')
    end

    it 'accepts serialisable arguments only' do
      expect(described_class.instance_method(:perform).parameters)
        .to eq([[:req, :match_ids]])
    end

    it 'is enqueueable with plain integers' do
      expect {
        described_class.perform_later([1, 2])
      }.to have_enqueued_job(described_class).with([1, 2]).on_queue('predictions')
    end
  end

  describe '#perform' do
    it 'requests a prediction for each scheduled match' do
      matches = [build_fixture, build_fixture(kickoff: Time.utc(2026, 8, 21, 15, 0))]
      predictor = instance_double(Predictions::Predictor)
      allow(Predictions::Predictor).to receive(:new).and_return(predictor)
      allow(predictor).to receive(:call) do
        Predictions::Predictor::Result.new(prediction: Prediction.new)
      end

      described_class.perform_now(matches.map(&:id))

      expect(predictor).to have_received(:call).twice
    end

    it 'skips matches that are already completed' do
      done = build_fixture(status: 'completed')
      predictor = instance_double(Predictions::Predictor)
      allow(Predictions::Predictor).to receive(:new).and_return(predictor)
      allow(predictor).to receive(:call) do
        Predictions::Predictor::Result.new(prediction: Prediction.new)
      end

      described_class.perform_now([done.id])

      expect(predictor).not_to have_received(:call)
    end

    it 'reports which matches succeeded and which failed' do
      ok_match = build_fixture
      bad_match = build_fixture(kickoff: Time.utc(2026, 8, 22, 15, 0))

      predictor = instance_double(Predictions::Predictor)
      allow(Predictions::Predictor).to receive(:new).and_return(predictor)
      allow(predictor).to receive(:call) do |match|
        if match.id == bad_match.id
          Predictions::Predictor::Result.new(message: 'the ML service is unreachable', transient: true)
        else
          Predictions::Predictor::Result.new(prediction: Prediction.new)
        end
      end

      outcome = described_class.perform_now([ok_match.id, bad_match.id])

      expect(outcome.succeeded).to eq([ok_match.id])
      expect(outcome.failed.keys).to eq([bad_match.id])
      expect(outcome.failed[bad_match.id]).to match(/unreachable/i)
    end

    it 'continues after a single failure instead of losing the whole batch' do
      first = build_fixture
      second = build_fixture(kickoff: Time.utc(2026, 8, 23, 15, 0))

      predictor = instance_double(Predictions::Predictor)
      allow(Predictions::Predictor).to receive(:new).and_return(predictor)
      calls = []
      allow(predictor).to receive(:call) do |match|
        calls << match.id
        if match.id == first.id
          Predictions::Predictor::Result.new(message: 'boom')
        else
          Predictions::Predictor::Result.new(prediction: Prediction.new)
        end
      end

      described_class.perform_now([first.id, second.id])

      expect(calls).to eq([first.id, second.id])
    end

    it 'ignores unknown match ids rather than raising' do
      outcome = described_class.perform_now([999_999])

      expect(outcome.succeeded).to eq([])
      expect(outcome.skipped).to eq([999_999])
    end

    it 'raises when every match failed, so the queue sees a failure' do
      match = build_fixture
      predictor = instance_double(Predictions::Predictor)
      allow(Predictions::Predictor).to receive(:new).and_return(predictor)
      allow(predictor).to receive(:call) do
        Predictions::Predictor::Result.new(message: 'the ML service is unreachable', transient: true)
      end

      expect {
        described_class.perform_now([match.id])
      }.to raise_error(PredictMatchesJob::AllPredictionsFailed)
    end

    it 'does not raise when at least one prediction succeeded' do
      ok_match = build_fixture
      bad_match = build_fixture(kickoff: Time.utc(2026, 8, 24, 15, 0))

      predictor = instance_double(Predictions::Predictor)
      allow(Predictions::Predictor).to receive(:new).and_return(predictor)
      allow(predictor).to receive(:call) do |match|
        if match.id == bad_match.id
          Predictions::Predictor::Result.new(message: 'boom')
        else
          Predictions::Predictor::Result.new(prediction: Prediction.new)
        end
      end

      expect { described_class.perform_now([ok_match.id, bad_match.id]) }.not_to raise_error
    end

    it 'logs a summary without leaking service internals' do
      match = build_fixture
      predictor = instance_double(Predictions::Predictor)
      allow(Predictions::Predictor).to receive(:new).and_return(predictor)
      allow(predictor).to receive(:call) do
        Predictions::Predictor::Result.new(prediction: Prediction.new)
      end
      allow(Rails.logger).to receive(:info)

      described_class.perform_now([match.id])

      expect(Rails.logger).to have_received(:info).with(/PredictMatchesJob/)
    end
  end
end
