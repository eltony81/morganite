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

  it "trims old dead jobs based on timeout" do
    original_timeout = Morganite.config.dead_timeout_in_seconds
    Morganite.config.dead_timeout_in_seconds = 1

    begin
      old_job = Morganite::Job.new(class: "FailingWorker", args: [JSON.parse("1")], retry: 0, retry_count: 0)
      Morganite::Failures.handle(old_job, Exception.new("boom"))

      redis = Morganite::RedisConnection.new_client
      sleep 1.1.seconds

      new_job = Morganite::Job.new(class: "FailingWorker", args: [JSON.parse("2")], retry: 0, retry_count: 0)
      Morganite::Failures.handle(new_job, Exception.new("boom"))

      redis.zcard(Morganite::Failures::DEAD_KEY).should eq(1)
    ensure
      Morganite.config.dead_timeout_in_seconds = original_timeout
    end
  end

  it "enforces dead_max_jobs limit" do
    original_max = Morganite.config.dead_max_jobs
    Morganite.config.dead_max_jobs = 2

    begin
      3.times do |i|
        job = Morganite::Job.new(class: "FailingWorker", args: [JSON.parse("#{i}")], retry: 0, retry_count: 0)
        Morganite::Failures.handle(job, Exception.new("boom"))
      end

      redis = Morganite::RedisConnection.new_client
      redis.zcard(Morganite::Failures::DEAD_KEY).should eq(2)
    ensure
      Morganite.config.dead_max_jobs = original_max
    end
  end
end
