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

    # Regression coverage for the JobIndex fix: the poller moves the job out
    # of morganite:retry via a Lua script that doesn't know about the index,
    # so the poller itself must deindex it — otherwise every job that's ever
    # retried leaves a permanent stale entry behind.
    redis.hget(Morganite::JobIndex::KEY, job.jid).should be_nil
  end

  it "keeps polling on later ticks after a Redis error" do
    # Regression test: poll had no rescue around it, so a single Redis
    # error (a real outage, a WRONGTYPE error, anything) would kill this
    # fiber forever — no more scheduled retries would ever get re-queued.
    # The same fix (and the same shape of test) applies to ScheduledPoller,
    # CronScheduler and OrphanReaper; this was also observed directly in
    # the e2e run surviving a real Redis disconnect without dying.
    redis = Morganite::RedisConnection.new_client
    redis.set(Morganite::Failures::RETRY_KEY, "not-a-sorted-set")

    poller = Morganite::RetryPoller.new(poll_interval: 0.1.seconds)
    spawn { poller.run }
    sleep 0.25.seconds # let it hit the WRONGTYPE error at least once

    redis.del(Morganite::Failures::RETRY_KEY)
    job = Morganite::Job.new(class: "FailingWorker", args: [] of JSON::Any)
    redis.zadd(Morganite::Failures::RETRY_KEY, Time.utc.to_unix, job.to_json)

    sleep 0.25.seconds
    poller.stop

    redis.zcard(Morganite::Failures::RETRY_KEY).should eq(0)
    redis.llen(job.queue_key).should eq(1)
  end
end
