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
    # *per-job* expiry (Section 8.8), opt-in via `timeout_seconds > 0`,
    # independent of whether the owning process/worker is otherwise alive
    # (that broader case is already covered by `OrphanReaper`).
    module Lease
      KEY = "morganite:jqcp:leases"

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
      end

      PROCESSING_PREFIX = "morganite:processing:"

      # Scans every `morganite:processing:*` list for a Job matching `jid`,
      # returning its owner (a wid, or `hostname:pid` for a native fiber
      # worker) and the Job. Unlike `find`, the caller doesn't need to
      # already know the owner — used by `LeaseReaper` (a `timeout_seconds`
      # lease entry doesn't record who claimed it; nothing else needs to)
      # and by the operator KillJob RPC's active-state case (Section 8.5).
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
