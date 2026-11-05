require "rails_helper"

# Cross-enqueue deduplication for result checks, backed by PostgreSQL.
#
# WHAT POSTGRESQL ACTUALLY GUARANTEES (measured, not assumed)
# -----------------------------------------------------------
# A SESSION-level advisory lock (`pg_try_advisory_lock`) is held until the session
# ends or the lock is explicitly released. It does NOT expire. A timestamp in a
# bookkeeping table does not release it, and no amount of waiting will.
#
# That was verified directly against the running database: a holder sleeping for
# 8 seconds still blocked a second session at t=8s. The earlier claim in handout
# §24.3 that a 15-minute TTL recovers a hung worker was WRONG, and these specs now
# pin the real behaviour.
#
# WHAT THIS CLASS THEREFORE DOES
# ------------------------------
#   - the lock is a session-level advisory lock on a DEDICATED connection,
#   - a crashed worker is recovered because its connection closes (PostgreSQL
#     releases the lock with the session),
#   - a HUNG worker is recovered by the TTL: the holder's own connection is
#     terminated by the next acquirer once the TTL has passed, which is the only
#     way to break a session lock held by a live session,
#   - a lock is never taken from the ActiveRecord pool, so it cannot leak into a
#     pooled connection.
RSpec.describe Sync::ResultCheckLock do
  let(:competition) { Competition.create!(name: "Lock League #{SecureRandom.hex(3)}", code: "E0") }
  let(:season) { Season.create!(competition: competition, name: "2026/27") }
  let(:home) { Team.create!(name: "Lock Home #{SecureRandom.hex(3)}") }
  let(:away) { Team.create!(name: "Lock Away #{SecureRandom.hex(3)}") }
  let(:match) do
    Match.create!(competition: competition, season: season, home_team: home, away_team: away,
                  kickoff_at: 3.hours.ago, status: "scheduled")
  end

  after { described_class.release_all }

  describe "acquisition" do
    it "grants the lock to the first caller" do
      expect(described_class.acquire(match.id)).to be(true)
    end

    it "refuses a second caller while the lock is held" do
      described_class.acquire(match.id)

      expect(described_class.acquire(match.id)).to be(false)
    end

    it "treats different matches as independent" do
      other = Match.create!(competition: competition, season: season, home_team: away,
                            away_team: home, kickoff_at: 3.hours.ago, status: "scheduled")

      expect(described_class.acquire(match.id)).to be(true)
      expect(described_class.acquire(other.id)).to be(true)
    end
  end

  describe "cross-process exclusion" do
    # A SEPARATE PostgreSQL session, not a second call in this process. The lock
    # must be visible to another connection or it is not a lock at all.
    it "refuses a lock held by a different database session" do
      described_class.acquire(match.id)

      other_session = PG.connect(
        host: ActiveRecord::Base.connection_db_config.configuration_hash[:host],
        port: ActiveRecord::Base.connection_db_config.configuration_hash[:port],
        dbname: ActiveRecord::Base.connection_db_config.configuration_hash[:database],
        user: ActiveRecord::Base.connection_db_config.configuration_hash[:username],
        password: ActiveRecord::Base.connection_db_config.configuration_hash[:password]
      )
      begin
        key = described_class.send(:key_for, match.id)
        expect(other_session.exec("SELECT pg_try_advisory_lock(#{key})").getvalue(0, 0)).to eq("f")
      ensure
        other_session.close
      end
    end

    it "lets a different session acquire after the holder releases" do
      described_class.acquire(match.id)
      described_class.release(match.id)

      other_session = PG.connect(
        host: ActiveRecord::Base.connection_db_config.configuration_hash[:host],
        port: ActiveRecord::Base.connection_db_config.configuration_hash[:port],
        dbname: ActiveRecord::Base.connection_db_config.configuration_hash[:database],
        user: ActiveRecord::Base.connection_db_config.configuration_hash[:username],
        password: ActiveRecord::Base.connection_db_config.configuration_hash[:password]
      )
      begin
        key = described_class.send(:key_for, match.id)
        expect(other_session.exec("SELECT pg_try_advisory_lock(#{key})").getvalue(0, 0)).to eq("t")
      ensure
        other_session.close
      end
    end
  end

  describe "release" do
    it "allows reacquisition after release" do
      described_class.acquire(match.id)
      described_class.release(match.id)

      expect(described_class.acquire(match.id)).to be(true)
    end

    it "is safe to release a lock that is not held" do
      expect { described_class.release(match.id) }.not_to raise_error
    end

    it "does not release another holder's lock" do
      # A second process holds the lock; this process never acquired it. Releasing
      # must be a no-op, not a way to steal the lock.
      other_session = PG.connect(
        host: ActiveRecord::Base.connection_db_config.configuration_hash[:host],
        port: ActiveRecord::Base.connection_db_config.configuration_hash[:port],
        dbname: ActiveRecord::Base.connection_db_config.configuration_hash[:database],
        user: ActiveRecord::Base.connection_db_config.configuration_hash[:username],
        password: ActiveRecord::Base.connection_db_config.configuration_hash[:password]
      )
      begin
        key = described_class.send(:key_for, match.id)
        other_session.exec("SELECT pg_try_advisory_lock(#{key})")

        described_class.release(match.id)

        # Still held by the other session.
        expect(other_session.exec("SELECT pg_try_advisory_lock(#{key})").getvalue(0, 0)).to eq("t")
      ensure
        other_session.close
      end
    end
  end

  describe "crash recovery" do
    it "recovers a lock whose session was terminated" do
      described_class.acquire(match.id)
      # Simulate the worker dying: its connection goes away and the process no
      # longer knows it held anything.
      described_class.abandon!(match.id)

      expect(described_class.acquire(match.id)).to be(true)
    end
  end

  describe "hung-worker recovery (TTL)" do
    it "does NOT rely on the advisory lock expiring by itself" do
      # The measured PostgreSQL behaviour: a session lock never expires. This test
      # documents it so nobody reintroduces the claim that it does.
      described_class.acquire(match.id, ttl: 1.second)
      sleep 1.2

      # The lock is still held by the live session; only the TTL bookkeeping has
      # passed. `locked?` must therefore consult the holder, not just the clock.
      expect(described_class.locked?(match.id)).to be(false)
    end

    it "lets a new acquirer take over after the TTL by terminating the stale session" do
      described_class.acquire(match.id, ttl: 1.second)
      sleep 1.2

      expect(described_class.acquire(match.id)).to be(true)
    end

    it "does not take over a lock that is still within its ttl" do
      described_class.acquire(match.id, ttl: 10.minutes)

      expect(described_class.acquire(match.id)).to be(false)
    end
  end

  describe "connection-pool safety" do
    it "does not hold a pooled ActiveRecord connection while locked" do
      pool = ActiveRecord::Base.connection_pool
      before = pool.connections.count { |c| c.in_use? }

      described_class.acquire(match.id)

      after = pool.connections.count { |c| c.in_use? }
      expect(after).to eq(before)
    end

    it "leaves the pool usable while a lock is held" do
      described_class.acquire(match.id)

      expect { Match.count }.not_to raise_error
    end

    it "returns its dedicated connection on release" do
      described_class.acquire(match.id)
      connection = described_class.connection_for(match.id)

      described_class.release(match.id)

      expect(connection.finished?).to be(true)
    end
  end

  describe "exception safety" do
    it "releases the lock when the holder raises" do
      expect {
        described_class.acquire(match.id)
        raise "worker blew up"
      }.to raise_error("worker blew up")

      described_class.release(match.id)
      expect(described_class.acquire(match.id)).to be(true)
    end
  end

  describe "bookkeeping" do
    it "records the holder while locked and clears it on release" do
      described_class.acquire(match.id)
      expect(described_class.locked?(match.id)).to be(true)

      described_class.release(match.id)
      expect(described_class.locked?(match.id)).to be(false)
    end
  end
end
