require "./redis_connection"
require "./logger"

module Morganite
  module RateLimiter
    PREFIX = "morganite:rate_limit:"

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

    def self.reschedule(job_json : String, queue_key : String)
      Morganite.pool.with do |redis|
        redis.lpush(queue_key, job_json)
      end
      Logger.debug("job rescheduled due to rate limit on #{queue_key}")
    end
  end
end
