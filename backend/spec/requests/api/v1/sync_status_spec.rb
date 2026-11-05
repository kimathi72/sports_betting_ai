require 'rails_helper'

# GET /api/v1/sync/status — the operational view of the daily synchronization.
#
# This is the endpoint an operator (or the mobile app's diagnostics screen) reads
# instead of shelling into the container. It must therefore be:
#
#   - read-only: a GET must never start, retry or reclaim a run;
#   - honest about staleness: a run that never succeeded is stale, not "unknown";
#   - free of secrets: the ledger already redacts, and this endpoint must keep it
#     that way through the serialization as well.
RSpec.describe 'GET /api/v1/sync/status', type: :request do
  # Writes a finished ledger row. `finished_at` defaults to just after the start
  # and can be moved back independently, so "succeeded a long time ago" is
  # expressible — which is the only way to test staleness.
  def complete(kind:, status:, started_at: Time.current, error: nil, finished_at: nil, **counts)
    run = Sync::SyncRun.create!(
      kind: kind, trigger: 'schedule', status: 'running', started_at: started_at
    )
    run.finish!(status: status, error: error, **counts)
    # `finish!` stamps finished_at with the current time, so a historical success
    # is backdated AFTER the run is closed.
    run.update!(finished_at: finished_at || started_at + 30.seconds)
    run.reload
  end

  it 'returns 200 with the documented top-level shape' do
    get '/api/v1/sync/status'

    expect(response).to have_http_status(:ok)
    body = response.parsed_body
    expect(body.keys).to match_array(%w[status checked_at schedules])
    expect(body['schedules'].keys).to match_array(%w[fixtures results])
  end

  it 'reports a never-run kind as stale with null timestamps' do
    get '/api/v1/sync/status'

    fixtures = response.parsed_body['schedules']['fixtures']
    expect(fixtures['last_success_at']).to be_nil
    expect(fixtures['last_attempt_at']).to be_nil
    expect(fixtures['stale']).to be(true)
    expect(fixtures['running']).to be(false)
    expect(response.parsed_body['status']).to eq('degraded')
  end

  it 'reports healthy once both kinds have succeeded recently' do
    complete(kind: 'fixtures', status: 'succeeded', fetched: 40, created: 2, updated: 1, skipped: 37)
    complete(kind: 'results', status: 'succeeded', fetched: 40, created: 0, updated: 4, skipped: 36)

    get '/api/v1/sync/status'

    body = response.parsed_body
    expect(body['status']).to eq('ok')
    expect(body['schedules']['fixtures']['stale']).to be(false)
    expect(body['schedules']['results']['last_attempt']['counts'])
      .to eq('fetched' => 40, 'created' => 0, 'updated' => 4, 'skipped' => 36, 'rejected' => 0)
  end

  it 'distinguishes the last attempt from the last success' do
    complete(kind: 'fixtures', status: 'succeeded', fetched: 10, created: 10)
    failed = complete(kind: 'fixtures', status: 'failed', fetched: 0, error: 'HTTP 404 unavailable')

    get '/api/v1/sync/status'

    fixtures = response.parsed_body['schedules']['fixtures']
    expect(fixtures['last_success_at']).to be_present
    expect(fixtures['last_attempt']['status']).to eq('failed')
    expect(fixtures['last_attempt']['error']).to include('404')
    # A failed attempt does not make fresh data stale.
    expect(fixtures['stale']).to be(false)
    expect(failed.last_error).to include('404')
  end

  it 'reports a running synchronization' do
    Sync::SyncRun.create!(kind: 'results', trigger: 'schedule', status: 'running',
                          started_at: Time.current)

    get '/api/v1/sync/status'

    expect(response.parsed_body['schedules']['results']['running']).to be(true)
    expect(response.parsed_body['schedules']['results']['last_attempt']['status']).to eq('running')
  end

  it 'marks data stale when the last success is older than the threshold' do
    complete(kind: 'fixtures', status: 'succeeded', started_at: 3.days.ago, finished_at: 3.days.ago)
    complete(kind: 'results', status: 'succeeded', started_at: 3.days.ago, finished_at: 3.days.ago)

    get '/api/v1/sync/status'

    expect(response.parsed_body['schedules']['fixtures']['stale']).to be(true)
    expect(response.parsed_body['status']).to eq('degraded')
  end

  it 'exposes a duration and never a credential' do
    complete(kind: 'results', status: 'failed',
             error: 'GET https://example.test/x?apikey=supersecret&season=2627 failed')

    get '/api/v1/sync/status'

    body = response.body
    expect(body).not_to include('supersecret')
    expect(body).to include('[FILTERED]')
    expect(response.parsed_body['schedules']['results']['last_attempt']['duration_seconds']).to be_a(Float)
  end

  it 'publishes the schedule so a client can show when the next run is due' do
    get '/api/v1/sync/status'

    schedule = response.parsed_body['schedules']['fixtures']['schedule']
    expect(schedule['cron']).to be_present
    expect(schedule['timezone']).to eq('UTC')
  end

  it 'is read-only: it never creates a run' do
    expect { get '/api/v1/sync/status' }.not_to change(Sync::SyncRun, :count)
  end
end
