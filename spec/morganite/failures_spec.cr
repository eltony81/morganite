require "../spec_helper"

describe Morganite::Failures do
  it "schedules a failed job for retry" do
    job = Morganite::Job.new(class: "FailingWorker", args: [JSON.parse("1")], retry_count: 0)

    Morganite::Failures.handle(job, Exception.new("boom"))

    redis = Morganite::RedisConnection.new_client
    redis.zcard(Morganite::Failures::RETRY_KEY).should eq(1)
    redis.zcard(Morganite::Failures::DEAD_KEY).should eq(0)
  end

  it "moves exhausted jobs to the dead queue" do
    job = Morganite::Job.new(class: "FailingWorker", args: [JSON.parse("1")], retry: 0, retry_count: 0)

    Morganite::Failures.handle(job, Exception.new("boom"))

    redis = Morganite::RedisConnection.new_client
    redis.zcard(Morganite::Failures::RETRY_KEY).should eq(0)
    redis.zcard(Morganite::Failures::DEAD_KEY).should eq(1)
  end

  it "discards jobs that raise Discard" do
    job = Morganite::Job.new(class: "FailingWorker", args: [JSON.parse("1")])

    Morganite::Failures.handle(job, Morganite::Discard.new("ignored"))

    redis = Morganite::RedisConnection.new_client
    redis.zcard(Morganite::Failures::RETRY_KEY).should eq(0)
    redis.zcard(Morganite::Failures::DEAD_KEY).should eq(0)
  end

  it "retries a dead job manually" do
    job = Morganite::Job.new(class: "FailingWorker", args: [JSON.parse("1")], retry: 0, retry_count: 0)
    Morganite::Failures.handle(job, Exception.new("boom"))

    Morganite::Failures.retry_dead(job.jid).should be_true

    redis = Morganite::RedisConnection.new_client
    redis.zcard(Morganite::Failures::DEAD_KEY).should eq(0)
    redis.llen("morganite:queue:default").should eq(1)
  end

  it "deletes a dead job" do
    job = Morganite::Job.new(class: "FailingWorker", args: [JSON.parse("1")], retry: 0, retry_count: 0)
    Morganite::Failures.handle(job, Exception.new("boom"))

    Morganite::Failures.delete_dead(job.jid).should be_true

    redis = Morganite::RedisConnection.new_client
    redis.zcard(Morganite::Failures::DEAD_KEY).should eq(0)
  end

  it "deletes a retry job" do
    job = Morganite::Job.new(class: "FailingWorker", args: [JSON.parse("1")], retry_count: 0)
    Morganite::Failures.handle(job, Exception.new("boom"))

    Morganite::Failures.delete_retry(job.jid).should be_true

    redis = Morganite::RedisConnection.new_client
    redis.zcard(Morganite::Failures::RETRY_KEY).should eq(0)
  end
end
