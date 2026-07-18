require "redis"
require "json"

# End-to-end test orchestrator.
# 1. Flushes Redis.
# 2. Enqueues a batch of jobs.
# 3. Polls the processed counter until it reaches the expected count or timeout.
module E2E
  REDIS_URL      = ENV.fetch("REDIS_URL", "redis://localhost:6379/0")
  QUEUE_NAME     = ENV.fetch("QUEUE_NAME", "demo")
  EXPECTED_COUNT = ENV.fetch("EXPECTED_COUNT", "100").to_i
  TIMEOUT        = ENV.fetch("TIMEOUT_SECONDS", "30").to_i
  COUNTER_KEY    = "morganite:e2e:processed"
  QUEUE_KEY      = "queue:#{QUEUE_NAME}"

  def self.redis
    Redis::Client.new(URI.parse(REDIS_URL))
  end

  def self.run
    redis = self.redis

    puts "[e2e] Flushing Redis..."
    redis.flushdb

    puts "[e2e] Enqueuing #{EXPECTED_COUNT} jobs..."
    EXPECTED_COUNT.times do |i|
      redis.lpush(QUEUE_KEY, {id: i + 1}.to_json)
    end

    puts "[e2e] Waiting for workers to process all jobs (timeout #{TIMEOUT}s)..."
    start = Time.utc
    loop do
      count = redis.get(COUNTER_KEY).try(&.to_i) || 0
      if count >= EXPECTED_COUNT
        puts "[e2e] SUCCESS: #{count}/#{EXPECTED_COUNT} jobs processed"
        exit 0
      end

      if (Time.utc - start).total_seconds >= TIMEOUT
        STDERR.puts "[e2e] FAILURE: only #{count}/#{EXPECTED_COUNT} jobs processed within #{TIMEOUT}s"
        exit 1
      end

      sleep 0.5.seconds
    end
  end
end

E2E.run
