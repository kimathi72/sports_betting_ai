require 'rails_helper'

# The synchronization ledger.
#
# Every scheduled or manual run gets one row. Without it there is no way to
# answer "did last night's import work?" — only Rails logs that scroll away, and
# a log line cannot be queried by "when did results last succeed?".
#
# The rules under test:
#   - exactly one row is OPEN per kind, so an overlap can be detected rather than
#     discovered as duplicate data later
#   - counts are recorded even on partial failure, because "0 created, 40
#     rejected" is the interesting case
#   - secrets never reach the "last error" text stored in the database
RSpec.describe Sync::SyncRun do
  describe 'lifecycle' do
    it 'starts running and records the trigger' do
      run = described_class.start!(kind: 'fixtures', trigger: 'schedule')

      expect(run).to be_running
      expect(run.started_at).to be_present
    end

    it 'records counts and finishes' do
      run = described_class.start!(kind: 'results', trigger: 'schedule')

      run.finish!(
        status: 'succeeded',
        fetched: 40, created: 2, updated: 5, skipped: 33, rejected: 0
      )

      run.reload
      expect(run).to be_succeeded
      expect(run.fetched).to eq(40)
      expect(run.created).to eq(2)
      expect(run.updated).to eq(5)
      expect(run.skipped).to eq(33)
      expect(run.finished_at).to be_present
      expect(run.duration_seconds).to be >= 0
    end

    it 'keeps counts on a partial failure' do
      run = described_class.start!(kind: 'results', trigger: 'schedule')

      run.finish!(status: 'failed', created: 0, rejected: 40, error: 'provider returned no FTR column')

      expect(run.reload).to be_failed
      expect(run.rejected).to eq(40)
      expect(run.last_error).to match(/FTR/)
    end

    it 'computes duration only once finished' do
      run = described_class.start!(kind: 'fixtures', trigger: 'manual')

      expect(run.duration_seconds).to be_nil
      run.finish!(status: 'succeeded')
      expect(run.reload.duration_seconds).to be_a(Float)
    end
  end

  describe 'overlap protection' do
    it 'refuses a second open run of the same kind' do
      described_class.start!(kind: 'fixtures', trigger: 'schedule')

      expect { described_class.start!(kind: 'fixtures', trigger: 'schedule') }
        .to raise_error(Sync::SyncRun::AlreadyRunning)
    end

    it 'allows a different kind to run concurrently' do
      described_class.start!(kind: 'fixtures', trigger: 'schedule')

      expect { described_class.start!(kind: 'results', trigger: 'schedule') }.not_to raise_error
    end

    it 'allows a new run once the previous one finished' do
      first = described_class.start!(kind: 'fixtures', trigger: 'schedule')
      first.finish!(status: 'succeeded')

      expect { described_class.start!(kind: 'fixtures', trigger: 'schedule') }.not_to raise_error
    end

    it 'enforces the single-open-run rule in the database, not only in Ruby' do
      # A retried Sidekiq job can start concurrently with a slow sibling in
      # another process; a model-level check alone would race.
      described_class.create!(kind: 'results', trigger: 'schedule', status: 'running',
                              started_at: Time.current)

      expect {
        described_class.create!(kind: 'results', trigger: 'schedule', status: 'running',
                                started_at: Time.current)
      }.to raise_error(ActiveRecord::RecordNotUnique)
    end

    it 'treats a stale open run as abandoned rather than blocking forever' do
      old = described_class.create!(kind: 'fixtures', trigger: 'schedule', status: 'running',
                                    started_at: (Sync::SyncRun::STALE_AFTER + 1.minute).ago)

      run = described_class.start!(kind: 'fixtures', trigger: 'schedule')

      expect(run).to be_running
      expect(old.reload).to be_failed
      expect(old.last_error).to match(/stale|abandoned/i)
    end
  end

  describe 'secrets' do
    it 'redacts anything that looks like a credential in the stored error' do
      run = described_class.start!(kind: 'results', trigger: 'schedule')

      run.finish!(status: 'failed',
                  error: 'GET https://example.test/x?apikey=supersecret123&season=2026/27 failed')

      expect(run.reload.last_error).not_to include('supersecret123')
      expect(run.last_error).to include('[FILTERED]')
    end
  end

  describe '.last_successful' do
    it 'returns the most recent successful run of a kind' do
      older = described_class.start!(kind: 'fixtures', trigger: 'schedule')
      older.finish!(status: 'succeeded')
      newer = described_class.start!(kind: 'fixtures', trigger: 'schedule')
      newer.finish!(status: 'succeeded')

      expect(described_class.last_successful('fixtures').id).to eq(newer.id)
    end

    it 'ignores failed runs' do
      described_class.start!(kind: 'results', trigger: 'schedule').finish!(status: 'failed')

      expect(described_class.last_successful('results')).to be_nil
    end
  end

  describe '.status_summary' do
    it 'reports last success, last attempt and staleness per kind' do
      run = described_class.start!(kind: 'fixtures', trigger: 'schedule')
      run.finish!(status: 'succeeded')

      summary = described_class.status_summary

      expect(summary[:fixtures][:last_success_at]).to be_present
      expect(summary[:fixtures][:last_attempt][:status]).to eq('succeeded')
      expect(summary[:fixtures][:stale]).to be(false)
    end

    it 'marks a kind stale when nothing has succeeded recently' do
      run = described_class.create!(kind: 'results', trigger: 'schedule', status: 'succeeded',
                                    started_at: 3.days.ago, finished_at: 3.days.ago)

      expect(described_class.status_summary[:results][:stale]).to be(true)
    end

    it 'marks a kind stale when it has never succeeded' do
      summary = described_class.status_summary

      expect(summary[:fixtures][:last_success_at]).to be_nil
      expect(summary[:fixtures][:stale]).to be(true)
    end
  end
end
