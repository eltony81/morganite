require "redis"
require_relative "worker"

# Sidekiq counterpart to Morganite's load_test.cr (examples/demo_app/src/load_test.cr):
# enqueues a batch of jobs, waits for a separately running Sidekiq process to
# drain them, and reports throughput/latency in the same format so the two
# can be compared directly. Not part of any test suite — run via
# scripts/run_benchmark.sh.

JOB_COUNT = ENV.fetch("JOB_COUNT", "20000").to_i
TIMEOUT_SECONDS = ENV.fetch("TIMEOUT_SECONDS", "180").to_i

redis = Redis.new(url: REDIS_URL)

puts "[sidekiq-bench] Flushing Redis..."
redis.flushdb

puts "[sidekiq-bench] Enqueuing #{JOB_COUNT} jobs..."
enqueue_start = Time.now
JOB_COUNT.times do |i|
  BenchWorker.perform_async(i + 1, Time.now.to_f)
end
enqueue_elapsed = Time.now - enqueue_start
enqueue_rate = enqueue_elapsed > 0 ? (JOB_COUNT / enqueue_elapsed).round(1) : 0
puts "[sidekiq-bench] Enqueued #{JOB_COUNT} jobs in #{enqueue_elapsed.round(2)}s (#{enqueue_rate} jobs/sec)"

puts "[sidekiq-bench] Waiting for drain (timeout #{TIMEOUT_SECONDS}s)..."
drain_start = Time.now

loop do
  count = redis.get(BenchWorker::COUNTER_KEY).to_i

  if count >= JOB_COUNT
    elapsed = Time.now - drain_start
    throughput = elapsed > 0 ? (count / elapsed).round(1) : 0
    latency_sum = redis.get(BenchWorker::LATENCY_KEY).to_f
    avg_latency_ms = count > 0 ? (latency_sum / count).round(2) : 0

    puts "[sidekiq-bench] SUCCESS: drained #{count}/#{JOB_COUNT} jobs in #{elapsed.round(2)}s"
    puts "[sidekiq-bench]   throughput:  #{throughput} jobs/sec"
    puts "[sidekiq-bench]   avg latency: #{avg_latency_ms}ms (enqueue -> processed)"
    exit 0
  end

  if Time.now - drain_start >= TIMEOUT_SECONDS
    warn "[sidekiq-bench] FAILURE: only #{count}/#{JOB_COUNT} jobs processed within #{TIMEOUT_SECONDS}s"
    exit 1
  end

  sleep 0.5
end
