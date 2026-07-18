require "../spec_helper"

class ConcurrencyDrainWorker
  include Morganite::Worker

  @@processed = [] of String
  @@mutex = Mutex.new

  def self.processed
    @@processed
  end

  def self.clear
    @@mutex.synchronize { @@processed.clear }
  end

  def perform(args)
    id = args[0].as_s
    @@mutex.synchronize { @@processed << id }
  end
end

class ConcurrentUniqueWorker
  include Morganite::Worker

  def perform(args)
  end
end

describe "Morganite concurrency" do
  it "drains a queue with multiple concurrent worker fibers without loss or duplication" do
    # Not covered anywhere else with concurrency > 1: proves reliable fetch
    # (BRPOPLPUSH) really does hand each job to exactly one worker fiber
    # when several are competing for the same queue.
    ConcurrencyDrainWorker.clear

    original_concurrency = Morganite.config.concurrency
    Morganite.config.concurrency = 5
    Morganite.reset_pool!

    begin
      job_count = 50
      job_count.times { |i| ConcurrencyDrainWorker.perform_async(i.to_s) }

      launcher = Morganite::Launcher.new(concurrency: 5, start_web: false)
      stopped = Channel(Nil).new
      spawn { launcher.run; stopped.send(nil) }

      start = Time.utc
      until ConcurrencyDrainWorker.processed.size >= job_count || (Time.utc - start).total_seconds > 5
        sleep 0.02.seconds
      end

      launcher.stop
      stopped.receive

      ConcurrencyDrainWorker.processed.size.should eq(job_count)
      ConcurrencyDrainWorker.processed.uniq.size.should eq(job_count)

      redis = Morganite::RedisConnection.new_client
      Morganite::RedisConnection.scan_keys(redis, "morganite:processing:*").each do |key|
        redis.llen(key).should eq(0)
      end
    ensure
      Morganite.config.concurrency = original_concurrency
      Morganite.reset_pool!
    end
  end

  it "lets exactly one concurrent enqueue win a until_executed unique lock" do
    fiber_count = 20
    results = Channel(Bool).new(fiber_count)

    fiber_count.times do
      spawn do
        job = Morganite::Client.enqueue(
          "ConcurrentUniqueWorker", [] of JSON::Any, "default",
          unique: "until_executed", unique_for: 60
        )
        results.send(!job.nil?)
      end
    end

    winners = (1..fiber_count).map { results.receive }
    winners.count(true).should eq(1)
  end

  it "never allows more than `limit` rate-limited calls through concurrently" do
    fiber_count = 30
    limit = 5
    results = Channel(Bool).new(fiber_count)

    fiber_count.times do
      spawn do
        results.send(Morganite::RateLimiter.allow?("ConcurrentRateLimitedWorker", limit, 60))
      end
    end

    allowed = (1..fiber_count).map { results.receive }
    allowed.count(true).should eq(limit)
  end
end
