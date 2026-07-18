require "morganite"
require "./workers/load_worker"

# Load test driver: enqueues a large batch of jobs, waits for a separately
# running `worker` process to drain them, and reports throughput and
# latency. Not part of `crystal spec` / CI — run via scripts/run_load_test.sh
# (podman/docker-compose), which starts `worker` as its own process/container
# so this is a real multi-process throughput measurement, not just fibers
# inside one process.
module LoadTest
  REDIS_URL   = ENV.fetch("REDIS_URL", "redis://localhost:6379/0")
  QUEUE_NAME  = ENV.fetch("QUEUE_NAME", "load")
  JOB_COUNT   = ENV.fetch("JOB_COUNT", "20000").to_i
  TIMEOUT     = ENV.fetch("TIMEOUT_SECONDS", "120").to_i
  COUNTER_KEY = LoadWorker::COUNTER_KEY
  LATENCY_KEY = LoadWorker::LATENCY_KEY

  Morganite.config = Morganite::Configuration.new(
    redis_url: REDIS_URL,
    queue: QUEUE_NAME,
  )

  def self.redis
    Morganite::RedisConnection.new_client
  end

  def self.run
    redis = self.redis

    puts "[load] Flushing Redis..."
    redis.flushdb

    puts "[load] Enqueuing #{JOB_COUNT} jobs..."
    enqueue_start = Time.utc
    JOB_COUNT.times do |i|
      payload = {id: i + 1, enqueued_at: Time.utc.to_unix_f}
      Morganite::Client.enqueue("LoadWorker", [JSON.parse(payload.to_json)], QUEUE_NAME)
    end
    enqueue_elapsed = (Time.utc - enqueue_start).total_seconds
    enqueue_rate = enqueue_elapsed > 0 ? (JOB_COUNT / enqueue_elapsed).round(1) : 0.0
    puts "[load] Enqueued #{JOB_COUNT} jobs in #{enqueue_elapsed.round(2)}s (#{enqueue_rate} jobs/sec)"

    puts "[load] Waiting for drain (timeout #{TIMEOUT}s)..."
    drain_start = Time.utc

    loop do
      count = redis.get(COUNTER_KEY).try(&.to_i) || 0

      if count >= JOB_COUNT
        report(redis, count, Time.utc - drain_start)
        exit 0
      end

      if (Time.utc - drain_start).total_seconds >= TIMEOUT
        STDERR.puts "[load] FAILURE: only #{count}/#{JOB_COUNT} jobs processed within #{TIMEOUT}s (jobs lost or stuck)"
        exit 1
      end

      sleep 0.5.seconds
    end
  end

  private def self.report(redis, count : Int32, elapsed : Time::Span)
    seconds = elapsed.total_seconds
    throughput = seconds > 0 ? (count / seconds).round(1) : 0.0
    latency_sum = redis.get(LATENCY_KEY).try(&.to_f) || 0.0
    avg_latency_ms = count > 0 ? (latency_sum / count).round(2) : 0.0

    puts "[load] SUCCESS: drained #{count}/#{JOB_COUNT} jobs in #{seconds.round(2)}s"
    puts "[load]   throughput:     #{throughput} jobs/sec"
    puts "[load]   avg latency:    #{avg_latency_ms}ms (enqueue -> processed)"
  end
end

LoadTest.run
