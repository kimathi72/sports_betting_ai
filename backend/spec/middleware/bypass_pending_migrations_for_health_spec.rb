require 'rails_helper'

# In development Rails inserts ActiveRecord::Migration::CheckPending into the
# middleware stack (config.active_record.migration_error == :page_load). That
# middleware opens a database connection before the request reaches the router,
# so a database outage turns even a liveness probe into a 500.
#
# This middleware short-circuits the health endpoints so they are evaluated
# before the pending-migration check can touch the database. It must pass every
# other request through untouched.
RSpec.describe BypassPendingMigrationsForHealth do
  let(:downstream) { ->(_env) { [200, { 'Content-Type' => 'text/plain' }, ['downstream']] } }
  let(:middleware) { described_class.new(downstream) }

  def env_for(path)
    Rack::MockRequest.env_for(path)
  end

  describe 'health endpoints' do
    it 'does not call the downstream app for /api/v1/health' do
      called = false
      app = ->(_env) { called = true; [200, {}, ['downstream']] }
      mw = described_class.new(app)

      status, _headers, body = mw.call(env_for('/api/v1/health'))

      expect(called).to be(false)
      expect(status).to eq(200)
      expect(body.join).to eq('{"status":"ok"}')
    end

    it 'does not call the downstream app for /api/v1/ready' do
      called = false
      app = ->(_env) { called = true; [200, {}, ['downstream']] }
      mw = described_class.new(app)

      mw.call(env_for('/api/v1/ready'))

      expect(called).to be(false)
    end

    it 'responds with JSON' do
      _status, headers, _body = middleware.call(env_for('/api/v1/health'))

      expect(headers['Content-Type']).to eq('application/json')
    end

    it 'answers liveness without touching the database' do
      expect(ActiveRecord::Base).not_to receive(:connection)

      middleware.call(env_for('/api/v1/health'))
    end
  end

  describe 'other requests' do
    it 'passes unrelated paths through to the downstream app' do
      expect(middleware.call(env_for('/api/v1/health/unknown')).last.join)
        .to eq('downstream')
    end

    it 'passes the root path through' do
      expect(middleware.call(env_for('/')).last.join).to eq('downstream')
    end

    it 'passes a differently-cased health path through' do
      expect(middleware.call(env_for('/api/v1/HEALTH')).last.join)
        .to eq('downstream')
    end
  end
end
