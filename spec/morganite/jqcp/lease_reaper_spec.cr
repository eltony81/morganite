require "../../spec_helper"
require "./support"

class JqcpLeaseTestWorker
  include Morganite::Worker

  def perform(args)
  end
end

describe Morganite::Jqcp::LeaseReaper do
  it "requeues a job whose Lease expired, without incrementing retry_count" do
    redis = Morganite::RedisConnection.new_client

    job = Morganite::Client.enqueue("JqcpLeaseTestWorker", [] of JSON::Any, timeout_seconds: 1_u32).should_not be_nil
    claimed_json = redis.brpoplpush(job.queue_key, "morganite:processing:lease-test-wid", timeout: 1).as(String)
    claimed = Morganite::Job.from_json(claimed_json)
    Morganite::Jqcp::Lease.track(redis, claimed)

    redis.zcard(Morganite::Jqcp::Lease::KEY).should eq(1)

    sleep 1.1.seconds

    reaper = Morganite::Jqcp::LeaseReaper.new(poll_interval: 200.milliseconds)
    spawn { reaper.run }
    sleep 500.milliseconds
    reaper.stop

    requeued = redis.lrange(job.queue_key, 0, -1)
    requeued.should be_a(Array(Redis::Value))
    requeued.as(Array).size.should eq(1)

    back = Morganite::Job.from_json(requeued.as(Array)[0].as(String))
    back.retry_count.should eq(0)

    redis.llen("morganite:processing:lease-test-wid").should eq(0)
    redis.zcard(Morganite::Jqcp::Lease::KEY).should eq(0)
  end

  it "leaves an unexpired Lease alone" do
    redis = Morganite::RedisConnection.new_client

    job = Morganite::Client.enqueue("JqcpLeaseTestWorker", [] of JSON::Any, timeout_seconds: 60_u32).should_not be_nil
    claimed_json = redis.brpoplpush(job.queue_key, "morganite:processing:lease-test-wid2", timeout: 1).as(String)
    claimed = Morganite::Job.from_json(claimed_json)
    Morganite::Jqcp::Lease.track(redis, claimed)

    reaper = Morganite::Jqcp::LeaseReaper.new(poll_interval: 200.milliseconds)
    spawn { reaper.run }
    sleep 500.milliseconds
    reaper.stop

    redis.llen("morganite:processing:lease-test-wid2").should eq(1)
    redis.zcard(Morganite::Jqcp::Lease::KEY).should eq(1)
  end
end
