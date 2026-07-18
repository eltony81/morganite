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

class DiscardingWorker
  include Morganite::Worker

  def perform(args)
    raise Morganite::Discard.new("nothing to do")
  end
end

class WhileExecutingLockedWorker
  include Morganite::Worker
  unique :while_executing

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

  it "drops an unparseable job payload without raising" do
    # Regression test: Job.from_json used to be called outside process's
    # rescue-guarded block, so a malformed payload would raise all the way
    # out of process and kill the calling worker fiber (see launcher.cr's
    # worker_loop).
    processor = Morganite::Processor.new
    processor.process("{not valid json")

    redis = Morganite::RedisConnection.new_client
    redis.zcard(Morganite::Failures::RETRY_KEY).should eq(0)
    redis.zcard(Morganite::Failures::DEAD_KEY).should eq(0)
  end

  it "retries a job for an unregistered worker class instead of raising" do
    # Regression test: WorkerRegistry.fetch used to be called outside
    # process's rescue-guarded block, so an unknown class would raise past
    # process (and kill the calling worker fiber) instead of going through
    # the normal retry/dead-letter path like any other job failure.
    job = Morganite::Job.new(class: "NoSuchWorkerAnywhere", args: [] of JSON::Any)

    processor = Morganite::Processor.new
    processor.process(job.to_json)

    redis = Morganite::RedisConnection.new_client
    redis.zcard(Morganite::Failures::RETRY_KEY).should eq(1)
  end

  it "fully drops a Discard'ed job without retrying or dead-lettering it" do
    Morganite::Client.enqueue("DiscardingWorker", [JSON.parse("1")], "default")
    redis = Morganite::RedisConnection.new_client
    payload = redis.rpop("morganite:queue:default").as(String)

    processor = Morganite::Processor.new
    processor.process(payload)

    redis.zcard(Morganite::Failures::RETRY_KEY).should eq(0)
    redis.zcard(Morganite::Failures::DEAD_KEY).should eq(0)
  end

  it "silently skips a while_executing job when the lock is already held" do
    WhileExecutingLockedWorker.clear
    job = Morganite::Job.new(class: "WhileExecutingLockedWorker", args: [] of JSON::Any, unique: "while_executing")
    Morganite::UniqueJobs.lock(job, ttl: 60).should be_true

    processor = Morganite::Processor.new
    processor.process(job.to_json)

    WhileExecutingLockedWorker.processed.should eq(0)

    redis = Morganite::RedisConnection.new_client
    redis.zcard(Morganite::Failures::RETRY_KEY).should eq(0)
    redis.zcard(Morganite::Failures::DEAD_KEY).should eq(0)
  end
end
