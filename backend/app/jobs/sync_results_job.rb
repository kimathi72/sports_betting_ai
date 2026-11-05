# Daily completed-result synchronization, run by the Sidekiq-Cron schedule
# `sync_results`.
#
# WHAT IT DOES
# ------------
# Refreshes the same current-season file as the fixture job and imports it through
# Sync::ResultSynchronizer, which is where the result-specific rules live:
#
#   - a row without both scores is NOT a completed match; it stays scheduled,
#   - a provider revision of an already-completed score is a conflict, not an
#     overwrite (the importer's long-standing rule),
#   - postponed stays postponed; nothing is invented.
#
# WHY IT IS SEPARATE FROM THE FIXTURE JOB
# ---------------------------------------
# Different risk profiles, different times. A broken fixture refresh must not stop
# results landing, and vice versa. Each kind has its own ledger row and its own
# overlap lock, so one hanging run cannot silently block the other.
#
# WHAT IT MUST NEVER DO
# ---------------------
# Retrain, re-predict in bulk, or promote a model. A newly imported result becomes
# training data for the next explicit training and evaluation run — it is never an
# automatic release.
class SyncResultsJob < ApplicationJob
  include ScheduledSynchronization

  def self.synchronizer_class
    Sync::ResultSynchronizer
  end

  def synchronizer_class
    self.class.synchronizer_class
  end
end
