require 'rails_helper'

# Contract for the versioned liveness endpoint the mobile app and load
# balancers poll. Liveness answers one question only: is the Rails process
# able to respond? It must therefore never touch the database or any other
# external dependency, or a dependency outage would wrongly mark the process
# as dead and trigger an unnecessary restart.
RSpec.describe 'API v1 liveness', type: :request do
  describe 'GET /api/v1/health' do
    it 'responds with HTTP 200' do
      get '/api/v1/health'

      expect(response).to have_http_status(:ok)
    end

    it 'returns JSON' do
      get '/api/v1/health'

      expect(response.media_type).to eq('application/json')
    end

    it 'returns a body reporting status "ok"' do
      get '/api/v1/health'

      expect(JSON.parse(response.body)).to eq('status' => 'ok')
    end

    it 'stays healthy when the database is unavailable' do
      # Liveness must not depend on PostgreSQL. Simulating a total connection
      # failure must leave the liveness response untouched.
      allow(ActiveRecord::Base).to receive(:connection)
        .and_raise(ActiveRecord::ConnectionNotEstablished, 'simulated outage')

      get '/api/v1/health'

      expect(response).to have_http_status(:ok)
      expect(JSON.parse(response.body)).to eq('status' => 'ok')
    end

    it 'does not expose environment details' do
      get '/api/v1/health'

      expect(response.body).not_to match(/password|secret|token|DATABASE_URL/i)
    end

    it 'stays healthy when Rails would check pending migrations first' do
      # Regression guard. In development the Active Record railtie inserts
      # ActiveRecord::Migration::CheckPending into the middleware stack when
      # config.active_record.migration_error == :page_load. That middleware
      # opens a database connection *before* the request reaches the router, so
      # a database outage would turn liveness into a 500. The spec turns the
      # middleware on and proves liveness still answers without a database.
      original = Rails.application.config.active_record.migration_error
      Rails.application.config.active_record.migration_error = :page_load
      Rails.application.reloader.prepare!

      allow(ActiveRecord::Base).to receive(:connection)
        .and_raise(ActiveRecord::ConnectionNotEstablished, 'simulated outage')

      get '/api/v1/health'

      expect(response).to have_http_status(:ok)
      expect(JSON.parse(response.body)).to eq('status' => 'ok')
    ensure
      Rails.application.config.active_record.migration_error = original
      Rails.application.reloader.prepare!
    end
  end
end
