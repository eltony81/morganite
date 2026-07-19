require "../job"
require "../redis_connection"
require "../logger"

module Morganite
  module Jqcp
    # JQCP Section 4.4: an Enqueue whose idempotency_key collides with an
    # existing non-terminal Job in the same queue MUST be rejected with
    # duplicate_idempotency_key (Section 5.3) instead of enqueued. This is a
    # separate mechanism from the existing `Morganite::UniqueJobs` feature
    # (which keys on a hash of class|queue|args and supports several
    # strategies) — idempotency_key is an explicit Producer-supplied token,
    # keyed only by queue + key, and simply blocks a second Enqueue outright
    # rather than offering while_executing/until_expired-style strategies.
    module Idempotency
      PREFIX = "morganite:jqcp:idem:"

      # Compare-and-delete, same rationale as `UniqueJobs::UNLOCK_SCRIPT`: a
      # release must only clear the reservation if it still points at this
      # job's jid, so a job whose reservation this call raced against a
      # newer reservation for the same key can't delete someone else's entry.
      RELEASE_SCRIPT = <<-LUA
        if redis.call('get', KEYS[1]) == ARGV[1] then
          return redis.call('del', KEYS[1])
        else
          return 0
        end
      LUA

      def self.key(queue : String, idempotency_key : String) : String
        "#{PREFIX}#{queue}:#{idempotency_key}"
      end

      # Atomically reserves `idempotency_key` for `job.jid` in `job.queue`.
      # Returns true if this call created the reservation (no collision),
      # false if a non-terminal Job already holds it.
      def self.reserve(redis : Redis::Client, job : Job) : Bool
        idem_key = job.idempotency_key
        return true unless idem_key

        result = redis.set(key(job.queue, idem_key), job.jid, nx: true)
        acquired = result == "OK"
        Logger.debug("jqcp idempotency key #{acquired ? "reserved" : "already held"} for queue=#{job.queue} key=#{idem_key}")
        acquired
      end

      # Releases the reservation once a Job leaves the non-terminal states
      # (succeeded, dead, or deleted) so the same idempotency_key can be
      # reused later.
      def self.release(redis : Redis::Client, job : Job)
        idem_key = job.idempotency_key
        return unless idem_key

        redis.eval(RELEASE_SCRIPT, keys: [key(job.queue, idem_key)], args: [job.jid])
        nil
      end
    end
  end
end
