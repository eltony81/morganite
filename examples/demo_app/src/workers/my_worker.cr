require "morganite"
require "redis"

class MyWorker
  include Morganite::Worker

  COUNTER_KEY = "morganite:e2e:processed"

  def perform(args)
    id = args[0]["id"].as_i
    redis = Redis::Client.new(URI.parse(ENV.fetch("REDIS_URL", "redis://localhost:6379/0")))
    redis.incr(COUNTER_KEY)
    puts "Processed job id=#{id}"
  end
end
