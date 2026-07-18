require "spec"
require "../src/morganite"

Morganite.config = Morganite::Configuration.new(
  redis_url: ENV.fetch("MORGANITE_REDIS_URL", "redis://localhost:6379/15"),
  queue: "default",
  concurrency: 1
)

Morganite::Logger.io = IO::Memory.new

def flush_redis
  redis = Morganite::RedisConnection.new_client
  redis.flushdb
end

Spec.before_each do
  flush_redis
end

Spec.after_each do
  flush_redis
end
