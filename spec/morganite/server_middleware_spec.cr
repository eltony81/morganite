require "../spec_helper"

class LoggingMiddleware
  include Morganite::ServerMiddleware

  @@calls = [] of String

  def self.calls
    @@calls
  end

  def self.clear
    @@calls.clear
  end

  def call(job, worker, queue, next_middleware)
    @@calls << "before:#{job.class}"
    next_middleware.call
    @@calls << "after:#{job.class}"
  end
end

class AddWorker
  include Morganite::Worker

  @@processed = [] of Array(JSON::Any)

  def self.processed
    @@processed
  end

  def self.clear
    @@processed.clear
  end

  def perform(args)
    @@processed << args
  end
end

describe Morganite::ServerMiddleware do
  before_each do
    Morganite::ServerMiddleware.clear
    LoggingMiddleware.clear
    AddWorker.clear
  end

  it "wraps job execution" do
    Morganite::ServerMiddleware.use(LoggingMiddleware.new)

    Morganite::Client.enqueue("AddWorker", [JSON.parse("1"), JSON.parse("2")], "default")
    redis = Morganite::RedisConnection.new_client
    payload = redis.rpop("morganite:queue:default").as(String)

    processor = Morganite::Processor.new
    processor.process(payload)

    AddWorker.processed.size.should eq(1)
    LoggingMiddleware.calls.should eq(["before:AddWorker", "after:AddWorker"])
  end
end
