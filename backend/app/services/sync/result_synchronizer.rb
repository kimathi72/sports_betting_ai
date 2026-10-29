module Sync
  # Daily completed-result synchronization.
  #
  # Imports the same current-season file as the fixture synchronizer, but its
  # purpose is the opposite end of the lifecycle: detect fixtures that now carry
  # a final score and reconcile them with the stored scheduled record.
  #
  # PUBLICATION DELAY
  # -----------------
  # A match is not final the moment it ends. The provider updates its file some
  # time afterwards, and occasionally revises a score. This job therefore:
  #
  #   - runs on its own daily schedule, later than the fixture refresh,
  #   - never invents a result: a row without both scores is not "completed",
  #     it is simply not yet published, and stays scheduled,
  #   - treats a CHANGED score for an already completed match as a conflict that
  #     aborts the batch (the importer's long-standing rule), rather than
  #     silently rewriting history a prediction was made against.
  #
  # It deliberately does NOT recompute predictions, retrain models or promote
  # artifacts. New results become training data for the next explicit training
  # and evaluation run — never an automatic deployment.
  class ResultSynchronizer < BaseSynchronizer
    KIND = 'results'.freeze

    # A result is published only once the provider has had time to update. Asking
    # for it immediately after full time just re-imports a file that still says
    # "scheduled", and the run then reports success with 0 new results, which
    # looks like a failure to an operator reading the ledger.
    def self.publication_delay
      ENV.fetch('SYNC_RESULT_PUBLICATION_DELAY_MINUTES', '60').to_i.minutes
    end

    private

    # Skip the provider call entirely when the newest fixture to have finished
    # is still inside the publication window: the file cannot contain its result
    # yet, so downloading it is a wasted request against a rate-limited source.
    def seasons_to_sync
      super
    end
  end
end
