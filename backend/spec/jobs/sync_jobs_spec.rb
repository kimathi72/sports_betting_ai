require 'rails_helper'

# The scheduled synchronization jobs.
#
# These specs exercise the JOB layer, which is deliberately thin: it decides
# whether to run, delegates to the synchronizer, and translates the outcome into
# a queue-level success or failure. All import behaviour is covered by
# spec/services/sync/, so it is mocked here on purpose — what is under test is
# the job's own contract:
#
#   - the right synchronizer kind is invoked,
#   - an overlap is NOT an error and NOT a silent no-op,
#   - a failed run raises, so Sidekiq records a failure instead of a green tick,
#   - a transient failure is retried a bounded number of times, a permanent one
#     is discarded immediately.
RSpec.describe 'Scheduled synchronization jobs' do
  def finished_run(kind:, status: 'succeeded', error: nil)
    run = Sync::SyncRun.create!(
      kind: kind, trigger: 'schedule', status: 'running', started_at: Time.current
    )
    run.finish!(status: status, fetched: 3, created: 1, updated: 1, skipped: 1, error: error)
    run
  end

  describe SyncFixturesJob do
    it 'runs the fixture synchronizer and does not raise on success' do
      run = finished_run(kind: 'fixtures')
      synchronizer = instance_double(Sync::FixtureSynchronizer, call: run)
      allow(Sync::FixtureSynchronizer).to receive(:new).and_return(synchronizer)

      expect { described_class.perform_now }.not_to raise_error

      expect(synchronizer).to have_received(:call).with(hash_including(trigger: 'schedule'))
    end

    it 'raises when the run failed, so the queue sees a failure' do
      run = finished_run(kind: 'fixtures', status: 'failed', error: 'HTTP 404')
      synchronizer = instance_double(Sync::FixtureSynchronizer, call: run)
      allow(Sync::FixtureSynchronizer).to receive(:new).and_return(synchronizer)

      expect { described_class.perform_now }.to raise_error(SyncFixturesJob::SynchronizationFailed, /404/)
    end

    it 'reports an overlap without failing the job' do
      synchronizer = instance_double(Sync::FixtureSynchronizer)
      allow(synchronizer).to receive(:call)
        .and_raise(Sync::SyncRun::AlreadyRunning, 'a fixtures synchronization is already running')
      allow(Sync::FixtureSynchronizer).to receive(:new).and_return(synchronizer)

      expect { described_class.perform_now }.not_to raise_error
    end

    it 'uses the fixtures queue' do
      expect(described_class.new.queue_name).to eq('sync')
    end
  end

  describe SyncResultsJob do
    it 'runs the result synchronizer and does not raise on success' do
      run = finished_run(kind: 'results')
      synchronizer = instance_double(Sync::ResultSynchronizer, call: run)
      allow(Sync::ResultSynchronizer).to receive(:new).and_return(synchronizer)

      expect { described_class.perform_now }.not_to raise_error
      expect(synchronizer).to have_received(:call).with(hash_including(trigger: 'schedule'))
    end

    it 'raises when the run failed' do
      run = finished_run(kind: 'results', status: 'failed', error: 'provider returned no files')
      synchronizer = instance_double(Sync::ResultSynchronizer, call: run)
      allow(Sync::ResultSynchronizer).to receive(:new).and_return(synchronizer)

      expect { described_class.perform_now }.to raise_error(SyncResultsJob::SynchronizationFailed)
    end

    it 'reports an overlap without failing the job' do
      synchronizer = instance_double(Sync::ResultSynchronizer)
      allow(synchronizer).to receive(:call)
        .and_raise(Sync::SyncRun::AlreadyRunning, 'a results synchronization is already running')
      allow(Sync::ResultSynchronizer).to receive(:new).and_return(synchronizer)

      expect { described_class.perform_now }.not_to raise_error
    end
  end

  describe 'retry policy' do
    # Retry classification is a property of the shared concern, not of each job,
    # so it is asserted once through one of the two concrete jobs.
    it 'discards a permanent failure instead of retrying it' do
      error = Sync::BaseSynchronizer::PermanentError.new('season not available')
      expect(SyncFixturesJob.retry_wait_for(0, error)).to eq(:discard)
    end

    it 'backoff increases with the attempt count on a transient failure' do
      error = Sync::BaseSynchronizer::TransientError.new('timed out')
      waits = (0..2).map { |count| SyncFixturesJob.retry_wait_for(count, error) }

      expect(waits).to all(be_a(Integer))
      expect(waits).to eq(waits.sort)
      expect(waits.last).to be > waits.first
    end

    it 'retries an unexpected error, because it may be a temporary outage' do
      expect(SyncResultsJob.retry_wait_for(0, StandardError.new('boom'))).to be_a(Integer)
    end

    it 'discards every non-retryable provider error class' do
      ScheduledSynchronization::NON_RETRYABLE.each do |klass|
        expect(SyncResultsJob.retry_wait_for(0, klass.new('x'))).to eq(:discard),
                                                                 "expected #{klass} to be discarded"
      end
    end

    it 'bounds the number of attempts' do
      expect(SyncFixturesJob.get_sidekiq_options['retry']).to eq(SyncFixturesJob::MAX_RETRIES)
      expect(SyncResultsJob.get_sidekiq_options['retry']).to eq(SyncResultsJob::MAX_RETRIES)
    end
  end

  describe 'separation from model training' do
    it 'never references the ML release or training workflow' do
      %w[sync_fixtures_job sync_results_job].each do |name|
        source = File.read(Rails.root.join("app/jobs/#{name}.rb"))
        expect(source).not_to match(/ReleaseStore|release_cli|train_|artifacts/)
      end
    end
  end
end
