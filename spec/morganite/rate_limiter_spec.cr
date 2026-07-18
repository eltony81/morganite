require "../spec_helper"

class RateLimitedWorker
  include Morganite::Worker

  rate_limit 1, 60

  @@processed = 0

  def self.processed
    @@processed
  end

  def self.clear
    @@processed = 0
  end

  def perform(args)
    @@processed += 1
  end
end

describe Morganite::RateLimiter do
  before_each do
    RateLimitedWorker.clear
  end

  it "allows the first job and delays the second one instead of busy-looping it" do
    # Regression test: reschedule used to LPUSH the rejected job straight
    # back onto the queue, so a worker could pull it right back off before
    # the window reset, get rejected again, and repeat — a busy-loop until
    # the window finally expired. It should be moved to morganite:scheduled
    # with a future score instead, removed from the queue entirely.
    Morganite::Client.enqueue("RateLimitedWorker", [JSON.parse("1")], "default")
    Morganite::Client.enqueue("RateLimitedWorker", [JSON.parse("2")], "default")

    redis = Morganite::RedisConnection.new_client
    processor = Morganite::Processor.new

    2.times do
      payload = redis.rpop("morganite:queue:default").as(String)
      processor.process(payload)
    end

    RateLimitedWorker.processed.should eq(1)
    redis.llen("morganite:queue:default").should eq(0)

    scheduled = redis.zrange("morganite:scheduled", 0, -1, with_scores: true).as(Array(Redis::Value))
    scheduled.size.should eq(2) # [job_json, score]
    score = scheduled[1].as(String).to_i64
    score.should be >= Time.utc.to_unix
  end

  it "allows exactly `limit` calls per window, not just one" do
    # Regression test: `allow?` used to seed the Redis counter with `limit`
    # only in Crystal memory, then DECR a key that didn't exist yet, which
    # Redis initializes at 0 and decrements to -1. So only the very first
    # call was ever allowed, regardless of `limit`.
    3.times do
      Morganite::RateLimiter.allow?("SomeBurstyWorker", 3, 60).should be_true
    end

    Morganite::RateLimiter.allow?("SomeBurstyWorker", 3, 60).should be_false
  end
end
