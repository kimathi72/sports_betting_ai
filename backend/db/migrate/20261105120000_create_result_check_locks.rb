class CreateResultCheckLocks < ActiveRecord::Migration[7.1]
  # Bookkeeping for the per-match result-check lock.
  #
  # THE LOCK ITSELF IS A POSTGRESQL ADVISORY LOCK, not this table. The advisory
  # lock is what actually prevents two workers checking the same match, and it is
  # released automatically when the holding session ends — so a killed worker
  # cannot leave a match permanently uncheckable.
  #
  # This table exists so an operator can answer "who is checking match N, and
  # since when?" without querying pg_locks, and so `locked?` can answer without
  # opening a second connection. It is deliberately NOT the authority: a stale row
  # here must never block a check.
  #
  # `expires_at` is a backstop for a hung-but-alive worker. It is not a lease that
  # must be renewed to keep the lock.
  def up
    create_table :result_check_locks do |t|
      t.bigint :match_id, null: false
      t.datetime :acquired_at, null: false
      t.datetime :expires_at, null: false
      t.timestamps
    end

    # One row per match: the lock is per match, not per attempt.
    add_index :result_check_locks, :match_id, unique: true
    add_index :result_check_locks, :expires_at
  end

  def down
    drop_table :result_check_locks
  end
end
