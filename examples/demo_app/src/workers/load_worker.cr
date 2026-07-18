require "morganite"
require "redis"

# Used by the load test (scripts/run_load_test.sh): records completion count
# and per-job enqueue-to-processed latency so the driver can report
# throughput and latency without needing its own database.
class LoadWorker
  include Morganite::Worker

  COUNTER_KEY = "morganite:load:processed"
  LATENCY_KEY = "morganite:load:latency_sum_ms"

  def perform(args)
    enqueued_at = args[0]["enqueued_at"].as_f
    latency_ms = (Time.utc.to_unix_f - enqueued_at) * 1000

    # Real jobs (HTTP calls, DB writes, ...) take long enough to have a
    # meaningful chance of being caught mid-flight by a crash. This no-op
    # job normally finishes in under a millisecond, which would make the
    # stress test's hard-kill scenario rarely actually catch anything in a
    # processing list to recover. ARTIFICIAL_DELAY_MS widens that window on
    # purpose; the plain load test leaves it unset (0).
    delay_ms = ENV.fetch("ARTIFICIAL_DELAY_MS", "0").to_i
    sleep delay_ms.milliseconds if delay_ms > 0

    redis = Redis::Client.new(URI.parse(ENV.fetch("REDIS_URL", "redis://localhost:6379/0")))
    redis.incr(COUNTER_KEY)
    redis.incrbyfloat(LATENCY_KEY, latency_ms)
  end
end
