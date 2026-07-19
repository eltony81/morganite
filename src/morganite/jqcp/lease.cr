require "../job"
require "../redis_connection"

module Morganite
  module Jqcp
    # A Lease (Section 2, Section 4.2's `timeout_seconds`) is the JQCP name
    # for what Morganite already implements as a job sitting in a
    # `morganite:processing:<owner>` list — `owner` is `wid` for jobs
    # claimed via the JQCP Worker API's Fetch, or `hostname:pid` for jobs
    # claimed by a native fiber worker (see `Launcher`). The
    # `morganite:jqcp:leases` ZSET adds only what's genuinely new: a
    # *per-job* expiry (Section 8.9, draft-difluri-jqcp-02 numbering; was 8.8
    # in -01), opt-in via `timeout_seconds > 0`,
    # independent of whether the owning process/worker is otherwise alive
    # (that broader case is already covered by `OrphanReaper`).
    module Lease
      KEY = "morganite:jqcp:leases"

      # Section 7.6 (RenewLease): where `max_lease_seconds` tracking lives.
      # Neither has anything to do with the Lease ZSET itself — `leased_at`
      # records the *original* Fetch time so cumulative ACTIVE time can be
      # computed across repeated renewals; `recently_killed` is a short-lived
      # courtesy flag so a worker's next RenewLease learns of a kill within
      # one renewal interval instead of only discovering it via job_not_found
      # once the grace window has passed (Appendix D's example numbers).
      LEASED_AT_PREFIX              = "morganite:jqcp:leased_at:"
      RECENTLY_KILLED_PREFIX        = "morganite:jqcp:recently_killed:"
      RECENTLY_KILLED_GRACE_SECONDS = 30

      def self.processing_key(wid : String) : String
        "morganite:processing:#{wid}"
      end

      def self.track(redis : Redis::Client, job : Job)
        return if job.timeout_seconds == 0

        expires_at = Time.utc.to_unix + job.timeout_seconds
        redis.zadd(KEY, expires_at, job.to_json)
      end

      def self.untrack(redis : Redis::Client, job : Job)
        redis.zrem(KEY, job.to_json)
      end

      # Extends an already-tracked Lease to `Time.utc + job.timeout_seconds`
      # from now (Section 7.6/8.4: RenewLease resets the Lease timeout the
      # same way a fresh Fetch would, it just doesn't reclaim the Job).
      # `track`'s own ZADD already updates-in-place when the member (the
      # Job's JSON) is unchanged, so this is exactly `track` again.
      def self.renew(redis : Redis::Client, job : Job)
        track(redis, job)
      end

      def self.leased_at_key(wid : String, jid : String) : String
        "#{LEASED_AT_PREFIX}#{wid}:#{jid}"
      end

      def self.recently_killed_key(wid : String, jid : String) : String
        "#{RECENTLY_KILLED_PREFIX}#{wid}:#{jid}"
      end

      # Called once, at the original Fetch, only for `max_lease_seconds > 0`
      # Jobs. TTL comfortably outlives `max_lease_seconds` so a claim that's
      # never Acked/Failed/renewed doesn't leak the key forever.
      def self.record_leased_at(redis : Redis::Client, wid : String, jid : String, max_lease_seconds : UInt32)
        redis.set(leased_at_key(wid, jid), Time.utc.to_unix.to_s, ex: max_lease_seconds + 60)
      end

      def self.leased_at(redis : Redis::Client, wid : String, jid : String) : Int64?
        value = redis.get(leased_at_key(wid, jid))
        value.is_a?(String) ? value.to_i64 : nil
      end

      def self.clear_leased_at(redis : Redis::Client, wid : String, jid : String)
        redis.del(leased_at_key(wid, jid))
      end

      def self.record_killed(redis : Redis::Client, wid : String, jid : String)
        redis.set(recently_killed_key(wid, jid), "1", ex: RECENTLY_KILLED_GRACE_SECONDS)
      end

      def self.recently_killed?(redis : Redis::Client, wid : String, jid : String) : Bool
        redis.get(recently_killed_key(wid, jid)).is_a?(String)
      end

      # Finds the Job matching `jid` currently leased to `wid` (i.e. present
      # in its processing list). Returns nil if no such Lease exists —
      # Section 8.2/8.3's job_not_found case (Lease already revoked,
      # expired and re-fetched, or Acked/Failed by a previous call).
      def self.find(redis : Redis::Client, wid : String, jid : String) : Job?
        result = redis.lrange(processing_key(wid), 0, -1)
        return nil unless result.is_a?(Array)

        result.each do |item|
          next unless item.is_a?(String)
          job = Job.from_json(item) rescue next
          return job if job.jid == jid
        end
        nil
      end

      # Removes the Job from wid's processing list and clears its Lease
      # entry — used once a Worker reports Ack/Fail for a Job it holds.
      def self.release(redis : Redis::Client, wid : String, job : Job)
        redis.lrem(processing_key(wid), 1, job.to_json)
        untrack(redis, job)
        clear_leased_at(redis, wid, job.jid)
      end

      PROCESSING_PREFIX = "morganite:processing:"

      # Scans every `morganite:processing:*` list for a Job matching `jid`,
      # returning its owner (a wid, or `hostname:pid` for a native fiber
      # worker) and the Job. Unlike `find`, the caller doesn't need to
      # already know the owner — used by `LeaseReaper` (a `timeout_seconds`
      # lease entry doesn't record who claimed it; nothing else needs to)
      # and by the operator KillJob RPC's active-state case (Section 8.6,
      # draft-difluri-jqcp-02 numbering; was 8.5 in -01).
      def self.find_anywhere(redis : Redis::Client, jid : String) : {String, Job}?
        RedisConnection.scan_keys(redis, "#{PROCESSING_PREFIX}*").each do |processing_key|
          owner = processing_key.sub(PROCESSING_PREFIX, "")
          result = redis.lrange(processing_key, 0, -1)
          next unless result.is_a?(Array)

          result.each do |item|
            next unless item.is_a?(String)
            job = Job.from_json(item) rescue next
            return {owner, job} if job.jid == jid
          end
        end
        nil
      end
    end
  end
end
