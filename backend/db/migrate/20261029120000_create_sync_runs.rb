# One row per synchronization attempt (fixtures or results).
#
# WHY A TABLE RATHER THAN LOG LINES
# ---------------------------------
# "Did last night's result import work?" must be answerable without shell access
# to the container. Logs scroll away and cannot be queried by time. This table is
# the operational ledger: last success per kind, record counts, the last error,
# and whether an import is currently running.
#
# The partial unique index is the important part. Two Sidekiq workers (or a
# retry racing a slow first attempt) must never import at the same time, and a
# Ruby-side check alone races. A partial index on `status = 'running'` makes the
# database itself refuse the second writer, while still allowing unlimited
# finished rows for the same kind.
class CreateSyncRuns < ActiveRecord::Migration[7.1]
  def change
    create_table :sync_runs do |t|
      t.string :kind, null: false
      t.string :trigger, null: false
      t.string :status, null: false, default: "running"

      t.datetime :started_at, null: false
      t.datetime :finished_at

      t.integer :fetched, null: false, default: 0
      t.integer :created, null: false, default: 0
      t.integer :updated, null: false, default: 0
      t.integer :skipped, null: false, default: 0
      t.integer :rejected, null: false, default: 0

      t.text :last_error
      t.jsonb :details, null: false, default: {}

      t.timestamps
    end

    add_index :sync_runs, %i[kind started_at]
    add_index :sync_runs, %i[status started_at]
    add_index :sync_runs, :kind, unique: true, where: "status = 'running'",
                                 name: "index_sync_runs_one_running_per_kind"
    add_check_constraint :sync_runs,
                         "status IN ('running', 'succeeded', 'failed')",
                         name: "sync_runs_status_check"
    add_check_constraint :sync_runs,
                         "kind IN ('fixtures', 'results')",
                         name: "sync_runs_kind_check"
  end
end
