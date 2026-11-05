module Sync
  # Cross-enqueue deduplication for result checks, backed by PostgreSQL.
  #
  # WHY NOT A RUBY MUTEX
  # --------------------
  # The dispatcher runs every five minutes and more than one worker can run it. An
  # in-memory mutex protects nothing across processes. Sidekiq's uniqueness plugin
  # is not installed, and adding a gem for one lock is a dependency the project
  # does not need.
  #
  # WHY ADVISORY LOCKS
  # ------------------
  # `pg_try_advisory_lock` is atomic, needs no table, and is released automatically
  # when the session ends — so a killed worker cannot leave a permanent lock
  # behind. That last property is the whole point: the failure this class must
  # prevent is "this match is silently never checked again", not "it is checked
  # twice".
  #
  # WHY A DEDICATED CONNECTION
  # --------------------------
  # A session-scoped advisory lock lives on the connection that took it. Taking it
  # from the Rails pool and holding it for the duration of a check starves the
  # pool — the first version of this class did exactly that and exhausted it. The
  # lock therefore uses its own short-lived PG connection, opened per acquisition
  # and closed on release. Closing the connection releases the lock, which is also
  # the crash-recovery path.
  #
  # THE TTL IS A BACKSTOP, NOT THE MECHANISM
  # ----------------------------------------
  # `ttl:` bounds how long a lock may be held. A crashed holder is recovered by its
  # connection closing. The TTL exists so a hung-but-alive worker cannot block a
  # match indefinitely.
  class ResultCheckLock
    DEFAULT_TTL = 15.minutes

    # A stable 64-bit key per match. Advisory locks take a bigint; the match id is
    # already unique, and the namespace keeps these locks from colliding with any
    # other advisory lock the application might take later.
    NAMESPACE = 0x5243_4b00 # "RCK\0"

    class << self
      # True when this caller now holds the lock.
      def acquire(match_id, ttl: DEFAULT_TTL)
        # An EXPIRED lock held by this process is abandoned, not held: the TTL is
        # the backstop for a hung worker, and honouring it here is what makes the
        # backstop real. Without this check a stuck job would block its own match
        # forever, which is the failure mode the lock exists to prevent.
        holder = HOLDERS[match_id]
        if holder
          return false if holder[:expires_at] > Time.current

          release(match_id)
        end

        connection = open_connection
        key = key_for(match_id)

        acquired = connection.exec("SELECT pg_try_advisory_lock(#{key})").getvalue(0, 0)
        unless acquired == "t"
          connection.close
          return false
        end

        HOLDERS[match_id] = { connection: connection, expires_at: Time.current + ttl }
        record_holder(match_id, ttl)
        true
      rescue PG::Error, ActiveRecord::StatementInvalid
        # A lock that cannot be taken must not be assumed: report failure so the
        # caller does not proceed without deduplication.
        release(match_id)
        false
      end

      def release(match_id)
        holder = HOLDERS.delete(match_id)

        if holder
          begin
            holder[:connection].exec("SELECT pg_advisory_unlock(#{key_for(match_id)})")
          rescue PG::Error
            # The session is already gone; the lock went with it.
            nil
          ensure
            begin
              holder[:connection].close
            rescue PG::Error
              nil
            end
          end
        end

        clear_holder(match_id)
        true
      end

      # True when a live lock is held. An expired row is NOT a live lock: the
      # advisory lock is the authority, and the row only describes it.
      def locked?(match_id)
        holder = HOLDERS[match_id]
        return true if holder && holder[:expires_at] > Time.current
        return false if holder # expired: not a live lock

        # Another process may hold it. The bookkeeping row is advisory, so it is
        # only trusted while unexpired; the advisory lock itself is the authority
        # and is checked by `acquire`.

        row = ActiveRecord::Base.connection.select_one(
          "SELECT 1 FROM result_check_locks WHERE match_id = #{Integer(match_id)} " \
          "AND expires_at > NOW()"
        )
        !row.nil?
      rescue ActiveRecord::StatementInvalid
        false
      end

      # Releases every lock this process holds. Used by tests and by a graceful
      # shutdown; a crashed process needs nothing because its connections close.
      def release_all
        HOLDERS.keys.each { |match_id| release(match_id) }
      end

      # The dedicated connection holding a match's lock, or nil. Public so a test
      # can prove the connection is closed on release and that a terminated
      # session is recoverable — both are properties of the lock, not internals.
      def connection_for(match_id)
        HOLDERS.dig(match_id, :connection)
      end

      # Drops this process's record of a lock WITHOUT unlocking it, simulating a
      # worker that died: the connection is closed, PostgreSQL releases the lock
      # with the session, and the process no longer knows it held anything.
      def abandon!(match_id)
        holder = HOLDERS.delete(match_id)
        return false if holder.nil?

        begin
          holder[:connection].close
        rescue PG::Error
          nil
        end
        true
      end

      private

      # A standalone connection, NOT one from the Rails pool: the lock must outlive
      # the job's own database work without occupying a pooled slot.
      def open_connection
        config = ActiveRecord::Base.connection_db_config.configuration_hash
        PG.connect(
          host: config[:host], port: config[:port], dbname: config[:database],
          user: config[:username], password: config[:password]
        )
      end

      def record_holder(match_id, ttl)
        ActiveRecord::Base.connection.execute(
          "INSERT INTO result_check_locks (match_id, acquired_at, expires_at, created_at, updated_at) " \
          "VALUES (#{Integer(match_id)}, NOW(), NOW() + INTERVAL '#{ttl.to_i} seconds', NOW(), NOW()) " \
          "ON CONFLICT (match_id) DO UPDATE SET acquired_at = NOW(), " \
          "expires_at = NOW() + INTERVAL '#{ttl.to_i} seconds', updated_at = NOW()"
        )
      rescue ActiveRecord::StatementInvalid
        # Bookkeeping only. The advisory lock is what gates acquisition, so a
        # failure here must not fail the acquisition.
        nil
      end

      def clear_holder(match_id)
        ActiveRecord::Base.connection.execute(
          "DELETE FROM result_check_locks WHERE match_id = #{Integer(match_id)}"
        )
      rescue ActiveRecord::StatementInvalid
        nil
      end

      def key_for(match_id)
        (NAMESPACE << 32) | (Integer(match_id) & 0xffff_ffff)
      end
    end

    # match_id => { connection:, expires_at: }
    HOLDERS = {}
  end
end
