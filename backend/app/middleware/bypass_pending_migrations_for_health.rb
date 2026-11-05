# Prevents ActiveRecord::Migration::CheckPending from contacting the database
# for health probes.
#
# Rails inserts CheckPending into the middleware stack when
# `config.active_record.migration_error == :page_load` (the development
# default). That middleware runs `check_pending_migrations` on the first
# request, which opens a database connection. During a database outage it
# raises before the request reaches the router, turning a liveness probe into a
# 500 — the exact opposite of what a liveness probe must do.
#
# This middleware sits immediately before CheckPending and answers the two
# documented health paths directly, without any database access. Readiness
# reuses the same controller action so its contract stays identical whichever
# layer answers it; the action itself performs the database check and returns
# 200 or 503 as documented.
#
# Every other request is passed through untouched — deliberately.
#
#   PENDING MIGRATIONS ARE STILL A 500 ON EVERY API PATH.
#
# On 2026-11-03 the two Phase C2 migrations were left unapplied in development
# (handout §18.8) and every `/api/v1/*` request raised PendingMigrationError.
# That is the correct behaviour: the code expects columns the schema does not
# have, and answering 200 from a stale schema would turn a loud failure into a
# quiet wrong answer. Widening this class to swallow the check would hide the
# only signal that says "run db:migrate".
#
# `spec/middleware/check_pending_visibility_spec.rb` pins that boundary: if a
# future change adds a path here, the spec fails and the decision has to be
# argued rather than slipped in.
class BypassPendingMigrationsForHealth
  HEALTH_PATHS = {
    "/api/v1/health" => :liveness,
    "/api/v1/ready" => :readiness
  }.freeze

  def initialize(app)
    @app = app
  end

  def call(env)
    return @app.call(env) unless env["REQUEST_METHOD"] == "GET"

    case HEALTH_PATHS[env["PATH_INFO"]]
    when :liveness
      json_response(200, "status" => "ok").tap do |response|
        response[1]["Cache-Control"] = "no-store"
      end
    when :readiness
      readiness_response
    else
      @app.call(env)
    end
  end

  private

  # Mirrors Api::V1::ReadyController#show. Kept here so readiness is also
  # reachable when CheckPending would otherwise block the request; the response
  # body and status codes are identical to the controller's contract.
  def readiness_response
    result = DatabaseHealthCheck.call

    body = {
      "status" => result.available? ? "ready" : "not_ready",
      "checks" => { "database" => result.status }
    }

    json_response(result.available? ? 200 : 503, body).tap do |response|
      response[1]["Cache-Control"] = "no-store"
    end
  end

  def json_response(status, body)
    payload = JSON.generate(body)
    [
      status,
      {
        "Content-Type" => "application/json",
        "Content-Length" => payload.bytesize.to_s
      },
      [payload]
    ]
  end
end
