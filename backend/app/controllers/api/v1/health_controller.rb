module Api
  module V1
    # Liveness probe for the versioned API surface. Deliberately does not touch
    # the database or any external service so it reports process health only.
    class HealthController < ApplicationController
      def show
        render json: { status: "ok" }
      end
    end
  end
end
