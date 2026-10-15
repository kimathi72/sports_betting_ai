module Api
  module V1
    # Readiness probe. Distinct from liveness: this endpoint answers whether the
    # application can serve requests that depend on its required dependencies.
    # PostgreSQL is the only required dependency in this milestone, so readiness
    # succeeds exactly when the database connection check succeeds.
    #
    # 200 + {"status":"ready","checks":{"database":"ok"}}         when reachable
    # 503 + {"status":"not_ready","checks":{"database":"unavailable"}} otherwise
    #
    # The response never includes credentials, SQL, connection strings or
    # exception messages; DatabaseHealthCheck reduces the outcome to a status.
    class ReadyController < ApplicationController
      def show
        result = DatabaseHealthCheck.call
        status = result.available? ? :ok : :service_unavailable

        render json: {
          status: result.available? ? "ready" : "not_ready",
          checks: { database: result.status },
        }, status: status
      end
    end
  end
end
