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
    batch.finish

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
    batch.finish

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

  it "fires completion callbacks exactly once under concurrent completions" do
    # Regression test: update_counters used to decrement "pending" with
    # HINCRBY but then re-read it with a separate HGET. Concurrent completions
    # could interleave between those two calls, so more than one fiber could
    # observe pending == 0 and fire the completion callbacks more than once.
    batch = Morganite::Batch.new(
      description: "concurrent batch",
      success_callback: "BatchSuccessWorker",
      complete_callback: "BatchCompleteWorker",
    )

    job_count = 25
    job_count.times { |i| batch.add("BatchStepWorker", [JSON.parse(i.to_s)]) }
    batch.finish

    done = Channel(Nil).new(job_count)
    job_count.times do
      spawn do
        Morganite::Batch.on_success(batch.bid)
        done.send(nil)
      end
    end
    job_count.times { done.receive }

    redis = Morganite::RedisConnection.new_client
    # job_count step jobs were already queued by `add`, plus exactly one
    # success callback and one complete callback if the fix holds.
    redis.llen("morganite:queue:default").should eq(job_count + 2)
  end

  it "does not fire completion callbacks more than once when real workers drain jobs while the batch is still being built" do
    # Regression test: Batch#add used to enqueue a job *before* incrementing
    # `pending`. With a real worker pool concurrently draining the queue
    # while `add` is still being called in a loop, a fast job could be
    # picked up and finish before its own increment ever ran, letting
    # `pending` legitimately cross zero more than once mid-build. The
    # spawn-based test above doesn't catch this: it only adds jobs *before*
    # firing concurrent completions, never *during*.
    batch = Morganite::Batch.new(
      description: "concurrent build+drain batch",
      success_callback: "BatchSuccessWorker",
      complete_callback: "BatchCompleteWorker",
    )

    job_count = 40
    # Deliberately not overriding concurrency: the global Morganite.pool is
    # sized from Morganite.config.concurrency (1 in spec_helper), and a
    # Launcher needs one long-held connection per worker fiber plus one for
    # fetch_loop. Asking for more workers than the pool can hand out
    # long-held connections for would deadlock. The fix being tested (bump
    # `pending` before enqueueing) is correct regardless of concurrency —
    # fibers still interleave with the add loop on every Redis I/O yield.
    launcher = Morganite::Launcher.new(start_web: false)
    stopped = Channel(Nil).new
    spawn { launcher.run; stopped.send(nil) }

    job_count.times { |i| batch.add("BatchStepWorker", [JSON.parse(i.to_s)]) }
    batch.finish

    start = Time.utc
    until BatchCompleteWorker.calls.size > 0 || (Time.utc - start).total_seconds > 5
      sleep 0.02.seconds
    end
    sleep 0.3.seconds # give any duplicate-fire race a moment to manifest

    launcher.stop
    stopped.receive

    BatchStepWorker.processed.size.should eq(job_count)
    BatchSuccessWorker.calls.size.should eq(1)
    BatchCompleteWorker.calls.size.should eq(1)
  end

  it "Batch.open calls finish automatically once the block returns" do
    Morganite::Batch.open(description: "block form", success: "BatchSuccessWorker", complete: "BatchCompleteWorker") do |batch|
      batch.add("BatchStepWorker", [JSON.parse("1")])
      batch.add("BatchStepWorker", [JSON.parse("2")])
    end

    redis = Morganite::RedisConnection.new_client
    2.times do
      payload = redis.rpop("morganite:queue:default").as(String)
      Morganite::Processor.new.process(payload)
    end

    2.times do
      payload = redis.rpop("morganite:queue:default")
      break unless payload.is_a?(String)
      Morganite::Processor.new.process(payload)
    end

    BatchSuccessWorker.calls.size.should eq(1)
    BatchCompleteWorker.calls.size.should eq(1)
  end
end
