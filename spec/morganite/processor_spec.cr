require "../spec_helper"

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

class FailingWorker
  include Morganite::Worker

  def perform(args)
    raise "boom"
  end
end

class WorkerMiddleware
  include Morganite::ServerMiddleware

  @@calls = [] of String

  def self.calls
    @@calls
  end

  def self.clear
    @@calls.clear
  end

  def call(job, worker, queue, next_middleware)
    @@calls << "worker:before"
    next_middleware.call
    @@calls << "worker:after"
  end
end

class WorkerWithMiddleware
  include Morganite::Worker

  server_middleware WorkerMiddleware

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

describe Morganite::Processor do
  before_each do
    AddWorker.clear
    WorkerWithMiddleware.clear
    WorkerMiddleware.clear
  end

  it "processes a job from JSON" do
    Morganite::Client.enqueue("AddWorker", [JSON.parse("1"), JSON.parse("2")], "default")
    redis = Morganite::RedisConnection.new_client
    payload = redis.rpop("morganite:queue:default").as(String)

    processor = Morganite::Processor.new
    processor.process(payload)

    AddWorker.processed.size.should eq(1)
    AddWorker.processed[0][0].as_i.should eq(1)
    AddWorker.processed[0][1].as_i.should eq(2)
  end

  it "moves failed jobs to the retry queue" do
    Morganite::Client.enqueue("FailingWorker", [JSON.parse("1")], "default")
    redis = Morganite::RedisConnection.new_client
    payload = redis.rpop("morganite:queue:default").as(String)

    processor = Morganite::Processor.new
    processor.process(payload)

    redis.zcard(Morganite::Failures::RETRY_KEY).should eq(1)
  end

  it "moves exhausted jobs to the dead queue" do
    job = Morganite::Job.new(
      class: "FailingWorker",
      args: [JSON.parse("1")],
      retry: 0,
      retry_count: 0
    )

    processor = Morganite::Processor.new
    processor.process(job.to_json)

    redis = Morganite::RedisConnection.new_client
    redis.zcard(Morganite::Failures::DEAD_KEY).should eq(1)
  end

  it "runs worker-specific middleware" do
    Morganite::Client.enqueue("WorkerWithMiddleware", [JSON.parse("1")], "default")
    redis = Morganite::RedisConnection.new_client
    payload = redis.rpop("morganite:queue:default").as(String)

    processor = Morganite::Processor.new
    processor.process(payload)

    WorkerWithMiddleware.processed.should eq(1)
    WorkerMiddleware.calls.should eq(["worker:before", "worker:after"])
  end
end
