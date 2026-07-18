require "../spec_helper"

describe Morganite::RetryPoller do
  it "moves mature retry jobs back to their queues" do
    job = Morganite::Job.new(class: "FailingWorker", args: [JSON.parse("1")], retry_count: 0)
    Morganite::Failures.handle(job, Exception.new("boom"))

    # Force the retry to be immediately mature
    redis = Morganite::RedisConnection.new_client
    redis.zadd(Morganite::Failures::RETRY_KEY, Time.utc.to_unix, job.to_json)

    poller = Morganite::RetryPoller.new(poll_interval: 0.1.seconds)
    spawn { poller.run }
    sleep 0.3.seconds
    poller.stop

    redis.zcard(Morganite::Failures::RETRY_KEY).should eq(0)
    redis.llen("morganite:queue:default").should eq(1)
  end
end
