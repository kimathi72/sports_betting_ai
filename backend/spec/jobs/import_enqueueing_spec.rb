require 'rails_helper'

# Enqueueing is not execution. These specs pin the enqueue contract — arguments,
# queue, and deferral — so that "the job was enqueued" is never mistaken for "the
# import happened". Actual execution through the configured worker is verified
# separately against Docker; see docs/roadmap.md.
RSpec.describe ImportFootballDataJob, 'enqueueing' do
  let(:fixture_path) do
    Rails.root.join('..', 'data', 'fixtures', 'football_data_premier_league_sample.csv').to_s
  end

  let(:season_label) { '2024/25' }

  describe '.perform_later' do
    it 'enqueues rather than running inline' do
      expect {
        described_class.perform_later(fixture_path, season_label)
      }.to have_enqueued_job(described_class).and change { Match.count }.by(0)
    end

    it 'enqueues with exactly the path and season label' do
      expect {
        described_class.perform_later(fixture_path, season_label)
      }.to have_enqueued_job(described_class).with(fixture_path, season_label)
    end

    it 'targets the imports queue' do
      expect {
        described_class.perform_later(fixture_path, season_label)
      }.to have_enqueued_job(described_class).on_queue('imports')
    end

    it 'publishes arguments that survive serialisation' do
      described_class.perform_later(fixture_path, season_label)
      enqueued = ActiveJob::Base.queue_adapter.enqueued_jobs.last

      # Only primitives cross the boundary into Redis; no AR objects, no IO.
      expect(enqueued[:args]).to all(be_a(String))
    end

    it 'rejects an unserialisable argument at enqueue time' do
      expect {
        described_class.perform_later(Object.new, season_label)
      }.to raise_error(ActiveJob::SerializationError)
    end
  end

  describe 'when executed later' do
    it 'imports at execution time, not enqueue time' do
      described_class.perform_later(fixture_path, season_label)
      expect(Match.count).to eq(0)

      perform_enqueued_jobs

      expect(Match.count).to eq(7)
    end

    it 'is safe to execute twice (retry after a duplicate delivery)' do
      described_class.perform_later(fixture_path, season_label)
      perform_enqueued_jobs
      described_class.perform_later(fixture_path, season_label)
      perform_enqueued_jobs

      expect(Match.count).to eq(7)
    end

    it 'surfaces a failure as a failed job, not a silent success' do
      described_class.perform_later('/nonexistent/nope.csv', season_label)

      expect { perform_enqueued_jobs }.to raise_error(ImportFootballDataJob::ImportFailed)
    end
  end
end
