# Sidekiq server configuration.
#
# Redis lives at REDIS_URL (Compose sets redis://redis:6379/0). Inside a container
# the hostname is the Compose service name, never localhost.
redis_url = ENV.fetch('REDIS_URL', 'redis://redis:6379/0')

Sidekiq.configure_server do |config|
  config.redis = { url: redis_url }

  # SCHEDULER STARTUP — failures in a boot hook must never take down the worker.
  #
  # sidekiq-cron stores its schedule in Redis and its poller is started by the
  # server, so a worker that boots after a restart picks the existing entries up
  # from Redis with no re-registration needed. We still call `register!` on every
  # boot for two reasons:
  #
  #   1. A fresh Redis (a new environment, a flushed instance) has no schedule at
  #      all. Without this the worker would run and never schedule anything, which
  #      is indistinguishable from "the jobs have not been due yet".
  #   2. Idempotent upsert by name means a changed cron in
  #      config/sidekiq_cron_schedule.rb takes effect on the next boot, without an
  #      operator editing entries by hand.
  #
  # The guard is on `Sidekiq.server?` semantics: this block only runs in a server
  # process, so a Rails console or a rake task never touches the schedule.
  config.on(:startup) do
    begin
      require Rails.root.join('config/sidekiq_cron_schedule').to_s

      # The MODE decides what is registered. The default is `disabled`, so a
      # worker started without an explicit SIDEKIQ_CRON_MODE registers nothing —
      # the safe outcome for a typo or a forgotten variable.
      warning = SidekiqCronSchedule.mode_warning
      Sidekiq.logger.warn("[sidekiq-cron] #{warning}") if warning

      names = SidekiqCronSchedule.register!
      if names.empty?
        Sidekiq.logger.info(
          "[sidekiq-cron] mode=#{SidekiqCronSchedule.mode}: no recurring jobs registered"
        )
      else
        Sidekiq.logger.info(
          "[sidekiq-cron] mode=#{SidekiqCronSchedule.mode}: registered #{names.join(', ')}"
        )
      end
    rescue StandardError => e
      # Logged loudly and not re-raised: a Redis hiccup at boot must not crash the
      # worker and take the import queues down with it. The next restart, or the
      # verification rake task, registers it again.
      Sidekiq.logger.error(
        "[sidekiq-cron] schedule registration FAILED (#{e.class}: #{e.message}); " \
        'recurring synchronization will NOT run until this is fixed'
      )
    end
  end

  # A cron scheduler whose thread died would silently stop scheduling. sidekiq-cron
  # logs this itself, but making it explicit means the absence of a scheduler is
  # visible in the log stream an operator already watches.
  config.on(:shutdown) do
    Sidekiq.logger.info('[sidekiq-cron] worker shutting down')
  end
end

Sidekiq.configure_client do |config|
  config.redis = { url: redis_url }
end
