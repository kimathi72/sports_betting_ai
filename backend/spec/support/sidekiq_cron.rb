# The recurring schedule is registered by the Sidekiq SERVER process at boot, and
# the suite never starts one. Without this file the schedule specs would assert
# against an empty Redis and the status endpoint would find no registered entry.
#
# The entries are written to the Redis that sidekiq-cron is configured to use and
# removed afterwards, so the suite leaves no schedule behind for a developer's
# local worker to pick up. Cleanup runs even when an example fails.
require Rails.root.join("config/sidekiq_cron_schedule").to_s

RSpec.configure do |config|
  config.before(:suite) do
    # The suite needs the FULL schedule present so the existing schedule specs and
    # the status endpoint have something to assert against. The default mode is
    # `disabled`, so it is set explicitly here — and restored afterwards, so a
    # developer's shell is not left with a mode they did not choose.
    @previous_cron_mode = ENV["SIDEKIQ_CRON_MODE"]
    ENV["SIDEKIQ_CRON_MODE"] = "all"
    SidekiqCronSchedule.register!
  end

  config.after(:suite) do
    SidekiqCronSchedule.names.each do |name|
      Sidekiq::Cron::Job.destroy(name)
    end

    if @previous_cron_mode.nil?
      ENV.delete("SIDEKIQ_CRON_MODE")
    else
      ENV["SIDEKIQ_CRON_MODE"] = @previous_cron_mode
    end
  end
end
