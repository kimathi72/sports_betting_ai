# Operational entry points for the daily synchronization.
#
# These exist so an operator never has to open a Rails console to answer:
#
#   - "is the schedule actually registered?"       -> sync:schedule:list
#   - "register it (again) without restarting"     -> sync:schedule:register
#   - "run it now, by hand"                        -> sync:fixtures / sync:results
#
# The manual runs record trigger "manual" (or the value given), so they are
# distinguishable from scheduled runs in the ledger.
namespace :sync do
  namespace :schedule do
    desc "List the recurring synchronization entries registered in Redis"
    task list: :environment do
      require Rails.root.join("config/sidekiq_cron_schedule").to_s
      expected = SidekiqCronSchedule.names
      registered = Sidekiq::Cron::Job.all.index_by(&:name)

      puts "Expected entries: #{expected.join(", ")}"
      puts "Registered:       #{registered.keys.sort.join(", ")}"
      missing = expected - registered.keys
      puts "MISSING:          #{missing.join(", ")}" if missing.any?

      expected.each do |name|
        job = registered[name]
        next unless job

        puts format("  %-16s cron=%-18s class=%-18s last_enqueue=%s",
                    job.name, job.cron, job.klass, job.last_enqueue_time || "never")
      end

      abort "schedule is incomplete" if missing.any?
    end

    desc "Register (upsert) the recurring synchronization entries"
    task register: :environment do
      require Rails.root.join("config/sidekiq_cron_schedule").to_s
      names = SidekiqCronSchedule.register!
      puts "Registered: #{names.join(", ")}"
    end
  end

  desc "Run the fixture synchronization now (add FORCE=1 to bypass the publication delay)"
  task fixtures: :environment do
    run = Sync::FixtureSynchronizer.new.call(trigger: ENV.fetch("TRIGGER", "manual"),
                                             force: ENV["FORCE"] == "1")
    puts "fixtures: #{run.status} fetched=#{run.fetched} created=#{run.created} " \
         "updated=#{run.updated} skipped=#{run.skipped} rejected=#{run.rejected}"
    puts "error: #{run.last_error}" if run.last_error
  end

  desc "Run the result synchronization now"
  task results: :environment do
    run = Sync::ResultSynchronizer.new.call(trigger: ENV.fetch("TRIGGER", "manual"))
    puts "results: #{run.status} fetched=#{run.fetched} created=#{run.created} " \
         "updated=#{run.updated} skipped=#{run.skipped} rejected=#{run.rejected}"
    puts "deferred: #{run.details["deferred"]}" if run.details["deferred"]
    puts "error: #{run.last_error}" if run.last_error
  end

  desc "Print the synchronization ledger summary"
  task status: :environment do
    Sync::SyncRun.status_summary.each do |kind, entry|
      puts "#{kind}: last_success=#{entry[:last_success_at] || "never"} " \
           "last_attempt=#{entry[:last_attempt_at] || "never"} " \
           "stale=#{entry[:stale]} running=#{entry[:running]}"
    end
  end
end
