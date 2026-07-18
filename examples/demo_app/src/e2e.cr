require "morganite"
require "./workers/my_worker"
require "./workers/rate_limited_worker"
require "./workers/batch_workers"

module E2E
  REDIS_URL      = ENV.fetch("REDIS_URL", "redis://localhost:6379/0")
  QUEUE_NAME     = ENV.fetch("QUEUE_NAME", "demo")
  EXPECTED_COUNT = ENV.fetch("EXPECTED_COUNT", "100").to_i
  TIMEOUT        = ENV.fetch("TIMEOUT_SECONDS", "30").to_i
  COUNTER_KEY    = "morganite:e2e:processed"

  RATE_LIMIT_COUNTER_KEY     = RateLimitedDemoWorker::COUNTER_KEY
  BATCH_SUCCESS_COUNTER_KEY  = BatchSuccessDemoWorker::COUNTER_KEY
  BATCH_COMPLETE_COUNTER_KEY = BatchCompleteDemoWorker::COUNTER_KEY

  Morganite.config = Morganite::Configuration.new(
    redis_url: REDIS_URL,
    queue: QUEUE_NAME,
  )

  def self.redis
    Morganite::RedisConnection.new_client
  end

  def self.fail(message : String)
    STDERR.puts "[e2e] FAILURE: #{message}"
    exit 1
  end

  def self.wait_for_counter(key : String, expected : Int32, label : String) : Int32
    puts "[e2e] Waiting for #{label} (target #{expected}, timeout #{TIMEOUT}s)..."
    start = Time.utc
    redis = self.redis

    loop do
      count = redis.get(key).try(&.to_i) || 0
      if count >= expected
        puts "[e2e] #{label}: #{count}/#{expected} OK"
        return count
      end

      if (Time.utc - start).total_seconds >= TIMEOUT
        fail("#{label} only reached #{count}/#{expected} within #{TIMEOUT}s")
      end

      sleep 0.5.seconds
    end
  end

  # Regression check for the CronExpression reachability guard: an impossible
  # day-of-month/month combination must be rejected immediately, rather than
  # silently accepted and left to spin CronScheduler's poll loop forever.
  def self.verify_cron_validation
    puts "[e2e] Verifying CronExpression rejects impossible day/month combinations..."

    begin
      Morganite::CronExpression.new("0 0 31 2 *")
      fail("expected CronExpression.new(\"0 0 31 2 *\") to raise (February 31st can never occur)")
    rescue
      puts "[e2e] cron validation OK: impossible expression raised as expected"
    end

    # A valid expression must still work normally.
    cron = Morganite::CronExpression.new("0 0 1 * *")
    next_time = cron.next(Time.utc(2026, 1, 1))
    fail("expected a valid cron expression to resolve to day 1, got #{next_time}") unless next_time.day == 1
    puts "[e2e] cron validation OK: valid expression still parses"
  end

  # Regression check for the rate limiter fix: `rate_limit(5, 10)` must allow
  # up to 5 jobs per 10s window. Before the fix, DECR on a never-seeded Redis
  # key meant only the very first job of the whole run was ever allowed.
  def self.verify_rate_limiter
    redis = self.redis
    limit = 5
    burst = 12

    puts "[e2e] Verifying rate limiter allows #{limit} jobs/window (burst of #{burst})..."

    burst.times do |i|
      Morganite::Client.enqueue("RateLimitedDemoWorker", [JSON.parse({id: i + 1}.to_json)], QUEUE_NAME)
    end

    sleep 1.5.seconds
    processed = redis.get(RATE_LIMIT_COUNTER_KEY).try(&.to_i) || 0

    if processed < 2
      fail("rate limiter allowed only #{processed} job(s) in the first window; " \
           "a limit=#{limit} rate limit should allow more than 1 (this is exactly the bug in issues.md #1)")
    end
    puts "[e2e] rate limiter allowed #{processed} jobs in the first window (> 1, fix verified)"

    wait_for_counter(RATE_LIMIT_COUNTER_KEY, burst, "rate-limited burst fully drained")
  end

  # Regression check for the batch completion race fix: many step jobs
  # completing concurrently across worker fibers must fire the success and
  # complete callbacks exactly once each, never more.
  def self.verify_batch_completion
    puts "[e2e] Verifying batch success/complete callbacks fire exactly once under concurrency..."

    batch = Morganite::Batch.new(
      description: "e2e batch",
      success_callback: "BatchSuccessDemoWorker",
      complete_callback: "BatchCompleteDemoWorker",
    )

    job_count = 30
    job_count.times { |i| batch.add("BatchStepDemoWorker", [JSON.parse({id: i + 1}.to_json)]) }
    batch.finish

    wait_for_counter(BATCH_COMPLETE_COUNTER_KEY, 1, "batch complete callback")

    # Give any duplicate-fire race a moment to manifest before asserting.
    sleep 1.5.seconds

    redis = self.redis
    success_calls = redis.get(BATCH_SUCCESS_COUNTER_KEY).try(&.to_i) || 0
    complete_calls = redis.get(BATCH_COMPLETE_COUNTER_KEY).try(&.to_i) || 0

    if success_calls != 1 || complete_calls != 1
      fail("expected exactly 1 success + 1 complete callback, got success=#{success_calls} complete=#{complete_calls} " \
           "(this is exactly the race in issues.md #2)")
    end
    puts "[e2e] batch callbacks fired exactly once each (fix verified)"
  end

  def self.run
    redis = self.redis

    puts "[e2e] Flushing Redis..."
    redis.flushdb

    verify_cron_validation

    puts "[e2e] Enqueuing #{EXPECTED_COUNT} jobs..."
    EXPECTED_COUNT.times do |i|
      Morganite::Client.enqueue("MyWorker", [JSON.parse({id: i + 1}.to_json)], QUEUE_NAME)
    end

    wait_for_counter(COUNTER_KEY, EXPECTED_COUNT, "baseline job processing")

    verify_rate_limiter
    verify_batch_completion

    puts "[e2e] SUCCESS: all scenarios passed (baseline processing, rate limiter, batch callbacks, cron validation)"
    exit 0
  end
end

E2E.run
