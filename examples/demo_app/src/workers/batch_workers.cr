require "morganite"
require "redis"

# Used by the e2e suite to prove the batch completion race fix: with many
# step jobs finishing concurrently across worker fibers, the success/complete
# callbacks must fire exactly once each, not more.
class BatchStepDemoWorker
  include Morganite::Worker

  def perform(args)
  end
end

class BatchSuccessDemoWorker
  include Morganite::Worker

  COUNTER_KEY = "morganite:e2e:batch_success_calls"

  def perform(args)
    redis = Redis::Client.new(URI.parse(ENV.fetch("REDIS_URL", "redis://localhost:6379/0")))
    redis.incr(COUNTER_KEY)
  end
end

class BatchCompleteDemoWorker
  include Morganite::Worker

  COUNTER_KEY = "morganite:e2e:batch_complete_calls"

  def perform(args)
    redis = Redis::Client.new(URI.parse(ENV.fetch("REDIS_URL", "redis://localhost:6379/0")))
    redis.incr(COUNTER_KEY)
  end
end
