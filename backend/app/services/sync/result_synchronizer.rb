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
  #     silently rewriting history a prediction was made against,
  #   - defers the provider call entirely while the newest pending fixture is
  #     still inside the publication window (see `deferral_reason`).
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

    # Skip the provider call entirely when the most recent fixture that should
    # already have finished is still inside the publication window. Such a fixture
    # cannot have a result in the file yet, so downloading it would spend a request
    # against a rate-limited source to learn nothing.
    #
    # The check is deliberately conservative: it only defers when there is a
    # pending fixture whose estimated end is inside the window. If no such fixture
    # is pending (nothing to wait for), the run proceeds, because there may be
    # older results still to reconcile or a fixture whose kickoff moved.
    def deferral_reason
      delay = self.class.publication_delay
      return nil if delay.zero?

      pending = Match.where(status: %w[scheduled in_progress])
                     .where(kickoff_at: ...Time.current)
                     .order(kickoff_at: :desc)
                     .first
      return nil if pending.nil?

      expected_final = pending.kickoff_at + estimated_duration
      return nil unless Time.current < expected_final + delay

      "latest pending fixture (match #{pending.id}) finished around " \
        "#{expected_final.utc.iso8601} and results are published after " \
        "#{delay.inspect}; retry later"
    end

    # A football match plus stoppage time. A fixed estimate is intentional: the
    # exact end time is not published for a fixture that has not finished, and the
    # window is already padded by `publication_delay`.
    def estimated_duration
      ENV.fetch('SYNC_MATCH_DURATION_MINUTES', '120').to_i.minutes
    end
  end
end
