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

describe Morganite::Processor do
  before_each do
    AddWorker.clear
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

  it "raises MissingWorkerError for unknown workers" do
    job = Morganite::Job.new(class: "UnknownWorker", args: [] of JSON::Any)

    processor = Morganite::Processor.new
    expect_raises(Morganite::MissingWorkerError) do
      processor.process(job.to_json)
    end
  end
end
