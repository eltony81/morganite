require "./redis_connection"
require "./logger"
require "./job"
require "./job_index"

module Morganite
  module RateLimiter
    PREFIX        = "morganite:rate_limit:"
    SCHEDULED_KEY = "morganite:scheduled"

    def self.allow?(worker_class : String, limit : Int32, window : Int32) : Bool
      return true if limit <= 0

      key = "#{PREFIX}#{worker_class}"

      Morganite.pool.with do |redis|
        # Seed the bucket with `limit` tokens the first time it's touched in a
        # window. NX means concurrent callers race harmlessly to create it once.
        if window > 0
          redis.set(key, limit.to_s, nx: true, ex: window)
        else
          redis.set(key, limit.to_s, nx: true)
        end

        remaining = redis.decr(key)
        remaining = remaining.is_a?(Int) ? remaining : -1

        if remaining >= 0
          Logger.debug("rate limit token acquired for #{worker_class} (#{remaining}/#{limit} remaining in window)")
          true
        else
          Logger.warn("rate limit exceeded for #{worker_class} (#{limit}/#{window}s)")
          false
        end
      end
    end

    # Delays the job until the rate-limit window is likely to have reset,
    # instead of putting it straight back on the queue. An immediate LPUSH
    # meant a worker could pull the same job right back off the queue before
    # the window reset, hit the limit again, and repeat — a busy-loop that
    # burned CPU/Redis calls (and produced a huge amount of log output) until
    # the window finally reset on its own. Reuses the existing
    # `morganite:scheduled` sorted set / ScheduledPoller machinery rather
    # than inventing a second delay mechanism.
    def self.reschedule(job_json : String, queue_key : String, worker_class : String, window : Int32)
      retry_at = retry_at(worker_class, window)

      Morganite.pool.with do |redis|
        redis.zadd(SCHEDULED_KEY, retry_at.to_unix, job_json)
        begin
          JobIndex.set(redis, SCHEDULED_KEY, Job.from_json(job_json))
        rescue ex : JSON::ParseException
        end
      end

      Logger.debug("job rescheduled due to rate limit on #{queue_key}, retrying at #{retry_at}")
    end

    private def self.retry_at(worker_class : String, window : Int32) : Time
      key = "#{PREFIX}#{worker_class}"
      ttl = Morganite.pool.with(&.ttl(key))
      seconds = ttl.is_a?(Int) && ttl > 0 ? ttl : window
      seconds = 1 if seconds <= 0
      Time.utc + seconds.seconds
    end
  end
end
