# Keep the health endpoints independent of the database.
#
# Rails inserts ActiveRecord::Migration::CheckPending into the middleware stack
# when `config.active_record.migration_error == :page_load` (the development
# default). CheckPending opens a database connection before the request reaches
# the router, so a database outage would turn the liveness probe into a 500 and
# trigger needless restarts.
#
# Inserting our middleware immediately before CheckPending lets the health
# paths be answered without any database access.
#
# The stack is frozen once the application has booted, so this has to run here
# in configuration rather than in an `after_initialize` hook. Initializers are
# evaluated before `app/middleware` is autoloaded, so the file is required
# explicitly rather than relying on Zeitwerk.
require Rails.root.join("app/middleware/bypass_pending_migrations_for_health")

# Only environments that actually configure CheckPending need the bypass.
if Rails.application.config.active_record.migration_error == :page_load
  Rails.application.config.middleware.insert_before(
    ActiveRecord::Migration::CheckPending,
    BypassPendingMigrationsForHealth
  )
end
