require "../spec_helper"

class TestWorker
  include Morganite::Worker

  def perform(args)
  end
end

class ScheduledWorker
  include Morganite::Worker

  def perform(args)
  end
end

describe Morganite::Worker do
  it "registers the worker and can enqueue jobs" do
    Morganite::WorkerRegistry.fetch("TestWorker").should be_a(Morganite::WorkerFactory)

    TestWorker.perform_async("hello", 42)

    redis = Morganite::RedisConnection.new_client
    redis.llen("morganite:queue:default").should eq(1)

    payload = redis.rpop("morganite:queue:default").as(String)
    job = Morganite::Job.from_json(payload)
    job.class.should eq("TestWorker")
    job.args[0].as_s.should eq("hello")
    job.args[1].as_i.should eq(42)
  end

  it "supports perform_in" do
    ScheduledWorker.perform_in(2.minutes, "x")

    redis = Morganite::RedisConnection.new_client
    redis.zcard("morganite:scheduled").should eq(1)
  end
end
