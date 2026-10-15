require 'rails_helper'

# Routing-level contract: only the documented health paths exist. These use
# `type: :routing` so the `be_routable` matcher and `route_to` are available;
# request specs elsewhere cover the HTTP behaviour of each path.
RSpec.describe 'API v1 health routing', type: :routing do
  it 'routes GET /api/v1/health to the versioned liveness action' do
    expect(get: '/api/v1/health').to route_to('api/v1/health#show')
  end

  it 'routes GET /api/v1/ready to the versioned readiness action' do
    expect(get: '/api/v1/ready').to route_to('api/v1/ready#show')
  end

  it 'does not route unknown health sub-paths' do
    expect(get: '/api/v1/health/unknown').not_to be_routable
  end

  it 'does not alias readiness under the health path' do
    expect(get: '/api/v1/health/ready').not_to be_routable
  end
end
