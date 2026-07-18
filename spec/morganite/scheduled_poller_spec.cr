require "../spec_helper"

describe Morganite::ScheduledPoller do
  it "moves mature scheduled jobs back to their queues" do
    Morganite::Client.schedule(
      "FailingWorker",
      Time.utc - 1.minute,
      [JSON.parse("1")],
      "default"
    )

    redis = Morganite::RedisConnection.new_client
    redis.zcard(Morganite::ScheduledPoller::SCHEDULED_KEY).should eq(1)

    poller = Morganite::ScheduledPoller.new(poll_interval: 0.1.seconds)
    spawn { poller.run }
    sleep 0.3.seconds
    poller.stop

    redis.zcard(Morganite::ScheduledPoller::SCHEDULED_KEY).should eq(0)
    redis.llen("morganite:queue:default").should eq(1)
  end
end
