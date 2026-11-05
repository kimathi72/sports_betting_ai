# The schedule constant lives in config/ rather than app/, because it is read by
# the Sidekiq boot hook before Rails has finished autoloading. Requiring it here
# makes the dependency explicit, so this controller works in any process (web,
# rake, spec) without relying on autoloading order.
require Rails.root.join('config/sidekiq_cron_schedule').to_s

module Api
  module V1
    # Operational status of the daily synchronization.
    #
    # READ ONLY. This endpoint must never start, retry or reclaim a run: a status
    # check that mutates state is a status check nobody can safely poll. Stale-run
    # reclamation happens inside SyncRun.start!, when the next attempt begins —
    # which is also the only moment reclaiming is correct.
    #
    # WHAT "healthy" MEANS HERE. `ok` means every kind has an attempt in progress
    # or a success inside SyncRun::STALE_AFTER_SUCCESS. `degraded` means at least
    # one kind is stale, which includes "has never succeeded" — a brand-new
    # deployment is honestly degraded rather than optimistically green.
    #
    # SECRETS. The ledger redacts credentials before they are stored, and this
    # controller re-emits only the fields it names explicitly. Provider payloads
    # and the download URL are never part of the response.
    class SyncStatusController < ApplicationController
      def show
        summary = Sync::SyncRun.status_summary
        # SCHEDULED kinds only. `match_check` is a per-match ledger kind, not a
        # recurring synchronization: it has no schedule, no staleness threshold and
        # no place in this contract. Including it would change the API response
        # shape for every existing consumer and report a permanent "stale" entry.
        schedules = Sync::SyncRun::SCHEDULED_KINDS.index_with do |kind|
          serialize_kind(kind, summary[kind.to_sym])
        end

        render json: {
          status: overall_status(summary),
          checked_at: Time.current.utc.iso8601,
          schedules: schedules
        }
      end

      private

      # `running` alone does not keep a kind healthy: a run that started weeks ago
      # and never finished is exactly the state an operator must be shown. The
      # ledger's own staleness window therefore decides, and `running` is reported
      # separately as a fact.
      def overall_status(summary)
        summary.values.all? { |entry| entry[:stale] == false } ? 'ok' : 'degraded'
      end

      def serialize_kind(kind, entry)
        {
          last_success_at: iso8601(entry[:last_success_at]),
          last_attempt_at: iso8601(entry[:last_attempt_at]),
          last_attempt: entry[:last_attempt] && {
            status: entry[:last_attempt][:status],
            trigger: entry[:last_attempt][:trigger],
            duration_seconds: duration_of(kind),
            counts: entry[:last_attempt][:counts],
            error: entry[:last_attempt][:error]
          },
          running: entry[:running],
          stale: entry[:stale],
          stale_after_hours: (Sync::SyncRun::STALE_AFTER_SUCCESS / 1.hour).to_i,
          schedule: schedule_for(kind)
        }
      end

      # Duration comes from the newest attempt row rather than the summary hash,
      # so `last_attempt_at` and `duration_seconds` always describe the same row.
      def duration_of(kind)
        run = Sync::SyncRun.last_attempt(kind)
        run&.duration_seconds
      end

      # The published schedule, read from the same constant the worker registers.
      # If the schedule ever diverges from what is actually registered in Redis,
      # the next-run time is omitted rather than guessed.
      def schedule_for(kind)
        entry = SidekiqCronSchedule::ENTRIES[kind]
        return nil if entry.nil?

        {
          cron: entry[:cron],
          timezone: SidekiqCronSchedule::TIMEZONE,
          description: entry[:description],
          next_run_at: next_run_at(entry[:cron])
        }
      end

      # Computed from the cron expression itself, not from sidekiq-cron's in-memory
      # state: this controller runs in the web process, which has no scheduler. A
      # cron with no next occurrence (a paused or malformed entry) yields nil.
      def next_run_at(cron)
        parsed = Fugit.parse_cron("#{cron} #{SidekiqCronSchedule::TIMEZONE}")
        return nil if parsed.nil?

        time = parsed.next_time(Time.current).to_t
        time&.utc&.iso8601
      rescue StandardError
        nil
      end

      def iso8601(value)
        value&.utc&.iso8601
      end
    end
  end
end
