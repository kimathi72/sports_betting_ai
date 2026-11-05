# Daily fixture synchronization, run by the Sidekiq-Cron schedule `sync_fixtures`.
#
# WHAT IT DOES
# ------------
# Refreshes the provider's current-season file and imports it, which:
#   - adds fixtures that have become available since the last run,
#   - moves kickoffs that the provider rescheduled,
#   - records postponements and cancellations as status changes,
#   - promotes a fixture that has since been played.
#
# It delegates all of that to Sync::FixtureSynchronizer. This class must not
# re-implement import rules: a second write path would be a second set of
# duplicate-protection and conflict rules to keep in step.
#
# WHAT IT MUST NEVER DO
# ---------------------
# Train, evaluate or promote a model. New fixtures are input for the next explicit
# training run, never a reason to deploy one. See the structural spec in
# spec/jobs/sync_jobs_spec.rb.
#
# The ledger row is the report: Sync::SyncRun holds the counts, duration, outcome
# and a redacted error. This job turns a failed row into a raised exception so the
# queue agrees with the ledger.
class SyncFixturesJob < ApplicationJob
  include ScheduledSynchronization

  def self.synchronizer_class
    Sync::FixtureSynchronizer
  end

  def synchronizer_class
    self.class.synchronizer_class
  end
end
