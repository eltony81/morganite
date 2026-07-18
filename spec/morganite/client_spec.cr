require "../spec_helper"

describe Morganite::Client do
  it "enqueues a job onto the Redis queue" do
    job = Morganite::Client.enqueue("MyWorker", [JSON.parse("\"x\"")], "default").as(Morganite::Job)

    redis = Morganite::RedisConnection.new_client
    redis.llen(job.queue_key).should eq(1)

    payload = redis.rpop(job.queue_key).as(String)
    restored = Morganite::Job.from_json(payload)
    restored.class.should eq("MyWorker")
    restored.args[0].as_s.should eq("x")
  end

  it "schedules a job in the scheduled set" do
    at = Time.utc + 5.minutes
    job = Morganite::Client.schedule("MyWorker", at, [JSON.parse("1")], "default").as(Morganite::Job)

    redis = Morganite::RedisConnection.new_client
    redis.zcard("morganite:scheduled").should eq(1)

    score = redis.zscore("morganite:scheduled", job.to_json)
    score.should eq(at.to_unix.to_s)
  end
end
