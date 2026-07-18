require "../spec_helper"

class OrphanReaperDemoWorker
  include Morganite::Worker

  def perform(args)
  end
end

describe Morganite::OrphanReaper do
  it "requeues jobs left behind by a process with no live heartbeat" do
    job = Morganite::Job.new(class: "OrphanReaperDemoWorker", args: [] of JSON::Any, queue: "default")
    processing_key = "morganite:processing:dead-host:1234"

    redis = Morganite::RedisConnection.new_client
    redis.lpush(processing_key, job.to_json)

    reaper = Morganite::OrphanReaper.new(poll_interval: 0.1.seconds)
    spawn { reaper.run }
    sleep 0.3.seconds
    reaper.stop

    redis.exists(processing_key).should eq(0)
    redis.llen(job.queue_key).should eq(1)
    redis.lrange(job.queue_key, 0, -1).as(Array(Redis::Value)).map(&.as(String)).should contain(job.to_json)
  end

  it "leaves a processing list alone while its owner's heartbeat is still alive" do
    job = Morganite::Job.new(class: "OrphanReaperDemoWorker", args: [] of JSON::Any, queue: "default")
    processing_key = "morganite:processing:live-host:5678"
    heartbeat_key = "morganite:processes:live-host:5678"

    redis = Morganite::RedisConnection.new_client
    redis.lpush(processing_key, job.to_json)
    redis.set(heartbeat_key, "1", ex: 45)

    reaper = Morganite::OrphanReaper.new(poll_interval: 0.1.seconds)
    spawn { reaper.run }
    sleep 0.3.seconds
    reaper.stop

    redis.llen(processing_key).should eq(1)
    redis.llen(job.queue_key).should eq(0)
  end
end
