require "../spec_helper"

describe Morganite::ScheduledPoller do
  it "moves mature scheduled jobs back to their queues" do
    job = Morganite::Client.schedule(
      "FailingWorker",
      Time.utc - 1.minute,
      [JSON.parse("1")],
      "default"
    ).as(Morganite::Job)

    redis = Morganite::RedisConnection.new_client
    redis.zcard(Morganite::ScheduledPoller::SCHEDULED_KEY).should eq(1)

    poller = Morganite::ScheduledPoller.new(poll_interval: 0.1.seconds)
    spawn { poller.run }
    sleep 0.3.seconds
    poller.stop

    redis.zcard(Morganite::ScheduledPoller::SCHEDULED_KEY).should eq(0)
    redis.llen("morganite:queue:default").should eq(1)

    # Regression coverage for the JobIndex fix: same reasoning as
    # RetryPoller — the Lua move script doesn't know about the index, so
    # the poller itself must deindex it after moving.
    redis.hget(Morganite::JobIndex::KEY, job.jid).should be_nil
  end
end
