require "../spec_helper"

class TagMiddleware
  include Morganite::ClientMiddleware

  def call(job, next_middleware)
    job.args << JSON.parse("\"tagged\"")
    next_middleware.call
  end
end

describe Morganite::ClientMiddleware do
  before_each do
    Morganite::ClientMiddleware.clear
  end

  it "modifies jobs before enqueue" do
    Morganite::ClientMiddleware.use(TagMiddleware.new)

    Morganite::Client.enqueue("AddWorker", [JSON.parse("1")], "default")

    redis = Morganite::RedisConnection.new_client
    payload = redis.rpop("morganite:queue:default").as(String)
    restored = Morganite::Job.from_json(payload)

    restored.args.size.should eq(2)
    restored.args[1].as_s.should eq("tagged")
  end
end
