module Sync
  # Daily fixture synchronization.
  #
  # Refreshes the provider's current-season file and imports it through the
  # standard importer, which is what publishes:
  #
  #   - newly listed fixtures (scheduled rows with no score),
  #   - moved kickoffs (the reschedule reconciliation added in Phase 2),
  #   - status changes scheduled -> postponed / cancelled,
  #   - a fixture that has since been played (promoted to completed).
  #
  # The last point matters: a season file mixes all three, so a single import
  # keeps fixtures and results consistent. The separate RESULT synchronizer
  # exists because the two have different risk profiles and different schedules —
  # a broken fixture refresh should not stop results landing, and vice versa.
  class FixtureSynchronizer < BaseSynchronizer
    KIND = 'fixtures'.freeze
  end
end
