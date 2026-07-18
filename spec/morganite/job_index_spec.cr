require "../spec_helper"

describe Morganite::JobIndex do
  it "finds a job it indexed, in the location it was indexed under" do
    job = Morganite::Job.new(class: "FailingWorker", args: [] of JSON::Any)
    redis = Morganite::RedisConnection.new_client
    redis.zadd("morganite:retry", Time.utc.to_unix, job.to_json)
    Morganite::JobIndex.set(redis, "morganite:retry", job)

    found = Morganite::JobIndex.find_in(redis, "morganite:retry", job.jid)
    found.should_not be_nil
    found.as(Morganite::Job).jid.should eq(job.jid)

    Morganite::JobIndex.find_in(redis, "morganite:dead", job.jid).should be_nil

    any = Morganite::JobIndex.find_any(redis, job.jid)
    any.should_not be_nil
    any.as(Tuple(Morganite::Job, String))[1].should eq("morganite:retry")
  end

  it "returns nil for a stale entry instead of a false positive" do
    # The job was indexed under morganite:retry but has since been removed
    # from that sorted set (e.g. a poller moved it, or it was deleted)
    # without the index being updated — the ZSCORE check must catch this.
    job = Morganite::Job.new(class: "FailingWorker", args: [] of JSON::Any)
    redis = Morganite::RedisConnection.new_client
    Morganite::JobIndex.set(redis, "morganite:retry", job)

    Morganite::JobIndex.find_in(redis, "morganite:retry", job.jid).should be_nil
    Morganite::JobIndex.find_any(redis, job.jid).should be_nil
  end

  it "deletes an entry, and delete_all deletes several at once" do
    job1 = Morganite::Job.new(class: "FailingWorker", args: [JSON.parse("1")])
    job2 = Morganite::Job.new(class: "FailingWorker", args: [JSON.parse("2")])
    redis = Morganite::RedisConnection.new_client

    redis.zadd("morganite:retry", Time.utc.to_unix, job1.to_json)
    redis.zadd("morganite:retry", Time.utc.to_unix, job2.to_json)
    Morganite::JobIndex.set(redis, "morganite:retry", job1)
    Morganite::JobIndex.set(redis, "morganite:retry", job2)

    Morganite::JobIndex.delete(redis, job1.jid)
    Morganite::JobIndex.find_any(redis, job1.jid).should be_nil
    Morganite::JobIndex.find_any(redis, job2.jid).should_not be_nil

    Morganite::JobIndex.delete_all(redis, [job2])
    Morganite::JobIndex.find_any(redis, job2.jid).should be_nil
  end

  it "falls back to a full scan when a job was never indexed" do
    # Simulates a job that predates this index (or any other reason the
    # index entry is simply missing): Failures must still find it via the
    # O(N) scan fallback, just without the fast path.
    job = Morganite::Job.new(class: "FailingWorker", args: [] of JSON::Any, retry: 0, retry_count: 0)
    redis = Morganite::RedisConnection.new_client
    redis.zadd(Morganite::Failures::DEAD_KEY, Time.utc.to_unix, job.to_json)

    Morganite::JobIndex.find_any(redis, job.jid).should be_nil
    Morganite::Failures.delete_dead(job.jid).should be_true
    redis.zcard(Morganite::Failures::DEAD_KEY).should eq(0)
  end
end
