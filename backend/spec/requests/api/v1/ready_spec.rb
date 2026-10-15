require 'rails_helper'

# Contract for the versioned readiness endpoint. Readiness answers a different
# question from liveness: is the application able to serve requests that depend
# on its required dependencies? For this milestone PostgreSQL is the only
# required dependency, so readiness must succeed exactly when the database
# connection check succeeds, and report 503 when it does not.
RSpec.describe 'API v1 readiness', type: :request do
  describe 'GET /api/v1/ready' do
    context 'when PostgreSQL is reachable' do
      it 'responds with HTTP 200' do
        get '/api/v1/ready'

        expect(response).to have_http_status(:ok)
      end

      it 'returns JSON' do
        get '/api/v1/ready'

        expect(response.media_type).to eq('application/json')
      end

      it 'reports the documented ready structure' do
        get '/api/v1/ready'

        expect(JSON.parse(response.body)).to eq(
          'status' => 'ready',
          'checks' => { 'database' => 'ok' }
        )
      end
    end

    context 'when PostgreSQL is unavailable' do
      before do
        # Simulate a database outage deterministically instead of stopping the
        # shared postgres container. The check layer must translate the driver
        # exception into the documented safe response.
        allow(DatabaseHealthCheck).to receive(:call)
          .and_return(DatabaseHealthCheck::Result.unavailable)
      end

      it 'responds with HTTP 503' do
        get '/api/v1/ready'

        expect(response).to have_http_status(:service_unavailable)
      end

      it 'returns JSON' do
        get '/api/v1/ready'

        expect(response.media_type).to eq('application/json')
      end

      it 'reports the documented not-ready structure' do
        get '/api/v1/ready'

        expect(JSON.parse(response.body)).to eq(
          'status' => 'not_ready',
          'checks' => { 'database' => 'unavailable' }
        )
      end

      it 'does not disclose connection details or exception messages' do
        get '/api/v1/ready'

        expect(response.body).not_to match(
          /password|secret|token|postgres:\/\/|PG::|ActiveRecord::|stack/i
        )
      end
    end
  end

  describe 'readiness scope' do
    it 'reports only the database, not unrelated dependencies' do
      get '/api/v1/ready'

      expect(JSON.parse(response.body).fetch('checks').keys).to eq(['database'])
    end
  end
end
