require "morganite"
require "redis"

# Used by the e2e suite to prove the rate limiter fix: allows `limit` jobs
# per window instead of collapsing to 1 regardless of the configured limit.
class RateLimitedDemoWorker
  include Morganite::Worker

  rate_limit 5, 10

  COUNTER_KEY = "morganite:e2e:rate_limited_processed"

  def perform(args)
    redis = Redis::Client.new(URI.parse(ENV.fetch("REDIS_URL", "redis://localhost:6379/0")))
    redis.incr(COUNTER_KEY)
  end
end
