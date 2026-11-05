class AddMatchCheckKindToSyncRuns < ActiveRecord::Migration[7.1]
  # A per-match result check needs its own ledger kind.
  #
  # WHY
  # ---
  # `sync_runs` has a partial unique index allowing ONE `running` row per kind.
  # That is correct for the daily synchronizations — two concurrent fixture
  # imports would fight over the same rows — but wrong for per-match checks: the
  # dispatcher enqueues several at once, and the first live run produced
  #
  #   Sync::SyncRun::AlreadyRunning: a results synchronization is already running
  #
  # for every check after the first. The checks still ran, but their ledger rows
  # were lost, which is the opposite of the observability the ledger exists for.
  #
  # `match_check` is a separate kind, so concurrent per-match checks each get their
  # own row while the daily `results` run keeps its single-run guarantee.
  #
  # The CHECK constraint on `kind` mirrors `Sync::SyncRun::KINDS`; both are updated
  # together. No existing row changes.
  OLD_KINDS = %w[fixtures results].freeze
  NEW_KINDS = %w[fixtures results match_check].freeze

  def up
    remove_check_constraint :sync_runs, name: "sync_runs_kind_check" if constraint_exists?("sync_runs_kind_check")

    add_check_constraint :sync_runs,
                         "kind IN (#{NEW_KINDS.map { |k| "'#{k}'" }.join(', ')})",
                         name: "sync_runs_kind_check"

    # THE INDEX IS THE REAL CONSTRAINT. A new kind alone does not help: the
    # partial unique index is on `kind` WHERE status = 'running', so two open
    # `match_check` rows still collide. The index is rebuilt to exclude
    # `match_check`, which is the kind that legitimately runs concurrently.
    #
    # The daily kinds keep their single-run guarantee exactly as before.
    remove_index :sync_runs, name: "index_sync_runs_one_running_per_kind"
    add_index :sync_runs, :kind,
              unique: true,
              where: "status = 'running' AND kind <> 'match_check'",
              name: "index_sync_runs_one_running_per_kind"
  end

  def down
    # Tightening back can only succeed if no `match_check` rows exist. If some do,
    # this raises rather than silently deleting the evidence of what ran.
    remove_index :sync_runs, name: "index_sync_runs_one_running_per_kind"
    add_index :sync_runs, :kind,
              unique: true,
              where: "status = 'running'",
              name: "index_sync_runs_one_running_per_kind"

    remove_check_constraint :sync_runs, name: "sync_runs_kind_check"

    add_check_constraint :sync_runs,
                         "kind IN (#{OLD_KINDS.map { |k| "'#{k}'" }.join(', ')})",
                         name: "sync_runs_kind_check"
  end

  private

  def constraint_exists?(name)
    select_value(
      "SELECT 1 FROM pg_constraint WHERE conname = #{quote(name)} AND conrelid = 'sync_runs'::regclass"
    ).present?
  end
end
