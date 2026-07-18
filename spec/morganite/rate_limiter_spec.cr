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

  it "allows the first job and reschedules the second one" do
    Morganite::Client.enqueue("RateLimitedWorker", [JSON.parse("1")], "default")
    Morganite::Client.enqueue("RateLimitedWorker", [JSON.parse("2")], "default")

    redis = Morganite::RedisConnection.new_client
    processor = Morganite::Processor.new

    payload = redis.rpop("morganite:queue:default").as(String)
    processor.process(payload)

    RateLimitedWorker.processed.should eq(1)

    # The second job should still be in the queue because it was rescheduled
    redis.llen("morganite:queue:default").should eq(1)
  end
end
