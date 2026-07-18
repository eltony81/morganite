require "../spec_helper"

class WorkflowStepOne
  include Morganite::Worker

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

class WorkflowStepTwo
  include Morganite::Worker

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

describe Morganite::Workflow do
  before_each do
    WorkflowStepOne.clear
    WorkflowStepTwo.clear
  end

  it "chains jobs sequentially" do
    workflow = Morganite::Workflow.new
    workflow.step("WorkflowStepOne", [JSON.parse("1")])
    workflow.step("WorkflowStepTwo", [JSON.parse("2")])
    workflow.run

    redis = Morganite::RedisConnection.new_client
    processor = Morganite::Processor.new

    # Process first step
    payload = redis.rpop("morganite:queue:default").as(String)
    processor.process(payload)

    WorkflowStepOne.processed.should eq(1)
    WorkflowStepTwo.processed.should eq(0)

    # Second step should have been enqueued
    redis.llen("morganite:queue:default").should eq(1)

    # Process second step
    payload = redis.rpop("morganite:queue:default").as(String)
    processor.process(payload)

    WorkflowStepTwo.processed.should eq(1)
    redis.llen("morganite:queue:default").should eq(0)
  end
end
