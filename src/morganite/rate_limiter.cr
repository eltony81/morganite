require "./redis_connection"

module Morganite
  module RateLimiter
    PREFIX = "morganite:rate_limit:"

    def self.allow?(worker_class : String, limit : Int32, window : Int32) : Bool
      return true if limit <= 0

      key = "#{PREFIX}#{worker_class}"

      Morganite.pool.with do |redis|
        current = redis.get(key)
        tokens = current.is_a?(String) ? current.to_i : limit

        if tokens > 0
          redis.decr(key)
          redis.expire(key, window) if current.nil?
          true
        else
          false
        end
      end
    end

    def self.reschedule(job_json : String, queue_key : String)
      Morganite.pool.with do |redis|
        redis.lpush(queue_key, job_json)
      end
    end
  end
end
