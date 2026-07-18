require "morganite"

# Used by the load test (scripts/run_load_test.sh) and the Sidekiq benchmark
# (scripts/run_benchmark.sh): records completion count and per-job
# enqueue-to-processed latency so the driver can report throughput and
# latency without needing its own database.
class LoadWorker
  include Morganite::Worker

  COUNTER_KEY = "morganite:load:processed"
  LATENCY_KEY = "morganite:load:latency_sum_ms"

  # A dedicated pool for this worker's own bookkeeping, sized to the same
  # concurrency and deliberately *separate* from Morganite.pool. Two reasons:
  # a fresh connection per job would measure this worker's own overhead as
  # much as the framework's; and reusing Morganite's internal pool from
  # inside a worker would nest a second borrow on top of the one worker_loop
  # already holds for the life of the fiber — with that pool sized only for
  # the framework's own needs (concurrency + 2, i.e. one spare slot total),
  # every worker fiber doing its own Redis I/O would serialize on that one
  # slot. A real job that needs its own Redis/DB access should use its own
  # pool, exactly like this.
  #
  # Built lazily, not at class-load time: this file is required before
  # demo_app.cr assigns the real Morganite.config (redis_url pointing at the
  # `redis` compose service, not localhost), so an eager pool here would
  # connect to the wrong host.
  @@pool : Morganite::RedisPool? = nil
  @@pool_mutex = Mutex.new

  private def pool : Morganite::RedisPool
    if existing = @@pool
      return existing
    end

    @@pool_mutex.synchronize do
      @@pool ||= Morganite::RedisPool.new(ENV.fetch("CONCURRENCY", "10").to_i + 2) { Morganite::RedisConnection.new_client }
    end

    @@pool.as(Morganite::RedisPool)
  end

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

    pool.with do |redis|
      redis.incr(COUNTER_KEY)
      redis.incrbyfloat(LATENCY_KEY, latency_ms)
    end
  end
end
