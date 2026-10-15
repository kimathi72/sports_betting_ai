# Answers one question for the readiness endpoint: can this process actually
# reach PostgreSQL right now?
#
# Kept deliberately small and dependency-free so the readiness failure path can
# be exercised in specs without stopping the shared database container. The
# class method is the seam the request specs stub.
class DatabaseHealthCheck
  # A tiny value object so callers never deal with raw booleans or driver
  # exceptions. `status` is the exact string published in the JSON contract.
  Result = Struct.new(:available, :status, keyword_init: true) do
    def available?
      available
    end

    def self.available
      new(available: true, status: "ok")
    end

    def self.unavailable
      new(available: false, status: "unavailable")
    end
  end

  # Runs a trivial round-trip to the database. Any failure to connect or to
  # execute the query means the process is not ready to serve database-backed
  # requests. The exception is swallowed on purpose: readiness must report a
  # safe status, never leak driver or connection details to the caller.
  def self.call
    ActiveRecord::Base.connection.select_value("SELECT 1")
    Result.available
  rescue ActiveRecord::ActiveRecordError, PG::Error => e
    Rails.logger.warn(
      "[readiness] database check failed: #{e.class}: #{e.message}"
    )
    Result.unavailable
  end
end
