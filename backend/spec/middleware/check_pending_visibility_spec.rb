require 'rails_helper'

# Regression test for the HTTP 500 seen on 2026-11-03.
#
# WHAT HAPPENED
# -------------
# Phase C2 added two migrations (`20261103120000_add_prospective_provenance_to_predictions`,
# `20261103121000_create_prospective_evaluation_records`) and left them unapplied in
# development, as §18.8 of the handover required. The next request to any API path
# raised `ActiveRecord::PendingMigrationError` from `CheckPending` — a 500 for every
# endpoint, including `/api/v1/predictions` and `/api/v1/competitions`. The bundled
# `BypassPendingMigrationsForHealth` middleware did not hide the cause; it only
# answers `/api/v1/health` and `/api/v1/ready` without a database connection, which
# is deliberate (a liveness probe must not fail during a database outage).
#
# WHY A SPEC RATHER THAN ONLY A MIGRATION
# ---------------------------------------
# Applying the migrations removes *this* instance of the failure. It does not stop
# the class of failure, and every observer of the incident should be able to read the
# answer without the database: this spec states, in code, which requests are
# insulated from a pending migration and which are not. If somebody "fixes" a future
# 500 by widening the bypass to every path, this spec fails and forces the decision
# into the open instead of quietly degrading the API to "responds 200 with no data".
RSpec.describe 'Pending migrations are visible to the API' do
  let(:downstream) { ->(_env) { [200, { 'Content-Type' => 'text/plain' }, ['downstream']] } }
  let(:middleware) { BypassPendingMigrationsForHealth.new(downstream) }

  # The routes the mobile client actually calls. Each must reach the application:
  # if it does not, it cannot report PendingMigrationError, and the developer sees
  # an empty 200 instead of the real problem.
  conservative_paths = [
    '/api/v1/predictions',
    '/api/v1/predictions/4357',
    '/api/v1/competitions',
    '/api/v1/seasons',
    '/api/v1/teams',
    '/api/v1/matches',
    '/api/v1/model_status',
    '/api/v1/sync/status'
  ]

  conservative_paths.each do |path|
    it "lets #{path} through so a pending migration is reported, not hidden" do
      status, _headers, body = middleware.call(Rack::MockRequest.env_for(path))

      expect(status).to eq(200)
      expect(body.join).to eq('downstream')
    end
  end

  it 'bypasses the health endpoints on purpose, and only those' do
    %w[/api/v1/health /api/v1/ready].each do |path|
      _status, headers, _body = middleware.call(Rack::MockRequest.env_for(path))

      expect(headers['Content-Type']).to eq('application/json')
    end
  end

  it 'does not bypass a write request even on a health path' do
    env = Rack::MockRequest.env_for('/api/v1/health', method: 'POST')

    expect(middleware.call(env).last.join).to eq('downstream')
  end

  # The development database is the one that raised. Assert the configuration that
  # produces the 500 is still the intended one: if `migration_error` were relaxed to
  # `:warn`, Rails would boot against a stale schema and the failure would move from
  # a loud 500 to a quiet 500 at the first query against a missing column.
  describe 'development migration checking' do
    it 'is configured to raise on the first request, not to warn' do
      development = Rails.root.join('config/environments/development.rb').read

      expect(development).to match(/config\.active_record\.migration_error = :page_load/)
    end
  end
end
