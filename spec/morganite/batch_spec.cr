require "../spec_helper"

class BatchStepWorker
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

class BatchSuccessWorker
  include Morganite::Worker

  @@calls = [] of String

  def self.calls
    @@calls
  end

  def self.clear
    @@calls.clear
  end

  def perform(args)
    @@calls << args[0].as_s
  end
end

class BatchCompleteWorker
  include Morganite::Worker

  @@calls = [] of String

  def self.calls
    @@calls
  end

  def self.clear
    @@calls.clear
  end

  def perform(args)
    @@calls << args[0].as_s
  end
end

class BatchFailingWorker
  include Morganite::Worker

  def perform(args)
    raise "batch boom"
  end
end

describe Morganite::Batch do
  before_each do
    BatchStepWorker.clear
    BatchSuccessWorker.clear
    BatchCompleteWorker.clear
  end

  it "executes success and complete callbacks when all jobs succeed" do
    batch = Morganite::Batch.new(
      description: "test batch",
      success_callback: "BatchSuccessWorker",
      complete_callback: "BatchCompleteWorker",
    )

    batch.add("BatchStepWorker", [JSON.parse("1")])
    batch.add("BatchStepWorker", [JSON.parse("2")])

    redis = Morganite::RedisConnection.new_client
    2.times do
      payload = redis.rpop("morganite:queue:default").as(String)
      processor = Morganite::Processor.new
      processor.process(payload)
    end

    BatchStepWorker.processed.size.should eq(2)

    # Process success and complete callback jobs
    2.times do
      payload = redis.rpop("morganite:queue:default")
      break unless payload.is_a?(String)
      processor = Morganite::Processor.new
      processor.process(payload)
    end

    BatchSuccessWorker.calls.size.should eq(1)
    BatchCompleteWorker.calls.size.should eq(1)
  end

  it "executes only complete callback when a job fails" do
    batch = Morganite::Batch.new(
      description: "failing batch",
      success_callback: "BatchSuccessWorker",
      complete_callback: "BatchCompleteWorker",
    )

    batch.add("BatchFailingWorker", [JSON.parse("1")])

    redis = Morganite::RedisConnection.new_client
    payload = redis.rpop("morganite:queue:default").as(String)
    processor = Morganite::Processor.new
    processor.process(payload)

    # Process complete callback job
    2.times do
      payload = redis.rpop("morganite:queue:default")
      break unless payload.is_a?(String)
      processor = Morganite::Processor.new
      processor.process(payload)
    end

    BatchSuccessWorker.calls.size.should eq(0)
    BatchCompleteWorker.calls.size.should eq(1)
  end
end
