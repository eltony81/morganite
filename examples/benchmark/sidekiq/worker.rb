require "sidekiq"
require "redis"
require "connection_pool"

REDIS_URL = ENV.fetch("REDIS_URL", "redis://localhost:6379/0")
CONCURRENCY = ENV.fetch("CONCURRENCY", "10").to_i

Sidekiq.configure_server do |config|
  config.redis = {url: REDIS_URL, size: CONCURRENCY + 2}
end

Sidekiq.configure_client do |config|
  config.redis = {url: REDIS_URL, size: 5}
end

# Counterpart to Morganite's LoadWorker (examples/demo_app/src/workers/load_worker.cr):
# records completion count and per-job enqueue-to-processed latency so
# bench.rb can report throughput/latency without its own database.
class BenchWorker
  include Sidekiq::Job

  COUNTER_KEY = "sidekiq_bench:processed"
  LATENCY_KEY = "sidekiq_bench:latency_sum_ms"

  # A dedicated pool for this worker's own bookkeeping, deliberately separate
  # from Sidekiq's own internal Redis pool — mirrors the Morganite LoadWorker
  # benchmark counterpart exactly, so neither side's numbers are skewed by
  # opening a fresh connection per job.
  @@pool = ConnectionPool.new(size: CONCURRENCY + 2, timeout: 5) { Redis.new(url: REDIS_URL) }

  def perform(id, enqueued_at)
    # Mirrors LoadWorker's ARTIFICIAL_DELAY_MS: unset (0) for the throughput
    # benchmark, only used to widen the in-flight window for stress-style runs.
    delay_ms = ENV.fetch("ARTIFICIAL_DELAY_MS", "0").to_i
    sleep(delay_ms / 1000.0) if delay_ms > 0

    latency_ms = (Time.now.to_f - enqueued_at) * 1000

    @@pool.with do |redis|
      redis.incr(COUNTER_KEY)
      redis.incrbyfloat(LATENCY_KEY, latency_ms)
    end
  end
end
