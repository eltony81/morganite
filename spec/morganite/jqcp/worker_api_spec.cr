require "../../spec_helper"
require "./support"

class JqcpPingWorker
  include Morganite::Worker

  def perform(args)
  end
end

private def worker_env(body : String) : HTTP::Server::Context
  Morganite::Jqcp::SpecSupport.fake_env(body, "test-worker-token")
end

private def redis
  Morganite::RedisConnection.new_client
end

describe Morganite::Jqcp::WorkerApi do
  describe ".hello" do
    it "creates an Identified session and returns the priority strategy" do
      result = Morganite::Jqcp::WorkerApi.hello(worker_env(%({"wid":"w1","queues":["default"],"concurrency":5})))
      result.should be_a(String)

      session = Morganite::Jqcp::WorkerSession.find(redis, "w1").should_not be_nil
      session.queues.should eq(["default"])
      session.concurrency.should eq(5)
    end

    it "rejects a request missing wid" do
      result = Morganite::Jqcp::WorkerApi.hello(worker_env(%({"queues":["default"]})))
      result.should be_a(Morganite::Jqcp::Errors::Rejection)
      result.as(Morganite::Jqcp::Errors::Rejection).reason.should eq("invalid_job")
    end
  end

  describe ".enqueue" do
    it "enqueues a job and returns it in Table 1 JSON shape" do
      result = Morganite::Jqcp::WorkerApi.enqueue(worker_env(%({"job":{"type":"JqcpPingWorker","queue":"default","args":[1,"x"]}})))
      result.should be_a(String)

      parsed = JSON.parse(result.as(String))
      parsed["state"].as_s.should eq("JOB_STATE_ENQUEUED")
      parsed["type"].as_s.should eq("JqcpPingWorker")
    end

    it "rejects a job missing type" do
      result = Morganite::Jqcp::WorkerApi.enqueue(worker_env(%({"job":{"queue":"default","args":[]}})))
      result.should be_a(Morganite::Jqcp::Errors::Rejection)
    end

    it "rejects a duplicate idempotency_key while the original job is still non-terminal" do
      body = %({"job":{"type":"JqcpPingWorker","queue":"default","args":[],"idempotencyKey":"dup-1"}})
      first = Morganite::Jqcp::WorkerApi.enqueue(worker_env(body))
      first.should be_a(String)

      second = Morganite::Jqcp::WorkerApi.enqueue(worker_env(body))
      second.should be_a(Morganite::Jqcp::Errors::Rejection)
      second.as(Morganite::Jqcp::Errors::Rejection).reason.should eq("duplicate_idempotency_key")
    end
  end

  describe ".fetch" do
    it "claims an eligible job and marks it Active" do
      Morganite::Jqcp::WorkerApi.hello(worker_env(%({"wid":"w-fetch","queues":["default"],"concurrency":5})))
      Morganite::Jqcp::WorkerApi.enqueue(worker_env(%({"job":{"type":"JqcpPingWorker","queue":"default","args":[]}})))

      result = Morganite::Jqcp::WorkerApi.fetch(worker_env(%({"wid":"w-fetch"})))
      result.should be_a(String)
      JSON.parse(result.as(String))["state"].as_s.should eq("JOB_STATE_ACTIVE")

      redis.llen("morganite:processing:w-fetch").should eq(1)
    end

    it "returns nil when no job becomes eligible before the budget elapses" do
      Morganite.config.jqcp_fetch_timeout_seconds = 1
      Morganite::Jqcp::WorkerApi.hello(worker_env(%({"wid":"w-empty","queues":["default"],"concurrency":5})))

      result = Morganite::Jqcp::WorkerApi.fetch(worker_env(%({"wid":"w-empty"})))
      result.should be_nil
    ensure
      Morganite.config.jqcp_fetch_timeout_seconds = 5
    end

    it "rejects Fetch for a wid that never said Hello" do
      result = Morganite::Jqcp::WorkerApi.fetch(worker_env(%({"wid":"never-said-hello"})))
      result.should be_a(Morganite::Jqcp::Errors::Rejection)
      result.as(Morganite::Jqcp::Errors::Rejection).reason.should eq("unauthorized")
    end
  end

  describe ".ack" do
    it "removes a leased job and rejects a second Ack for the same jid" do
      Morganite::Jqcp::WorkerApi.hello(worker_env(%({"wid":"w-ack","queues":["default"],"concurrency":5})))
      enq = JSON.parse(Morganite::Jqcp::WorkerApi.enqueue(worker_env(%({"job":{"type":"JqcpPingWorker","queue":"default","args":[]}}))).as(String))
      jid = enq["jid"].as_s
      Morganite::Jqcp::WorkerApi.fetch(worker_env(%({"wid":"w-ack"})))

      result = Morganite::Jqcp::WorkerApi.ack(worker_env(%({"wid":"w-ack","jid":"#{jid}"})))
      result.should be_a(String)
      redis.llen("morganite:processing:w-ack").should eq(0)

      again = Morganite::Jqcp::WorkerApi.ack(worker_env(%({"wid":"w-ack","jid":"#{jid}"})))
      again.should be_a(Morganite::Jqcp::Errors::Rejection)
      again.as(Morganite::Jqcp::Errors::Rejection).reason.should eq("job_not_found")
    end
  end

  describe ".fail" do
    it "schedules a retry (count < max) with the reported error fields" do
      Morganite::Jqcp::WorkerApi.hello(worker_env(%({"wid":"w-fail","queues":["default"],"concurrency":5})))
      enq = JSON.parse(Morganite::Jqcp::WorkerApi.enqueue(worker_env(%({"job":{"type":"JqcpPingWorker","queue":"default","args":[]}}))).as(String))
      jid = enq["jid"].as_s
      Morganite::Jqcp::WorkerApi.fetch(worker_env(%({"wid":"w-fail"})))

      result = Morganite::Jqcp::WorkerApi.fail(worker_env(%({"wid":"w-fail","jid":"#{jid}","errtype":"Net::SMTPError","message":"boom"})))
      result.should be_a(String)

      retried = redis.zrange("morganite:retry", 0, -1)
      retried.should be_a(Array(Redis::Value))
      job = Morganite::Job.from_json(retried.as(Array)[0].as(String))
      job.retry_count.should eq(1)
      job.error_type.should eq("Net::SMTPError")
      job.error_message.should eq("boom")
    end

    it "moves the job to dead once retry.max is exhausted" do
      Morganite::Jqcp::WorkerApi.hello(worker_env(%({"wid":"w-dead","queues":["default"],"concurrency":5})))
      enq = JSON.parse(Morganite::Jqcp::WorkerApi.enqueue(worker_env(%({"job":{"type":"JqcpPingWorker","queue":"default","args":[],"retry":{"max":1}}}))).as(String))
      jid = enq["jid"].as_s
      Morganite::Jqcp::WorkerApi.fetch(worker_env(%({"wid":"w-dead"})))

      Morganite::Jqcp::WorkerApi.fail(worker_env(%({"wid":"w-dead","jid":"#{jid}","message":"boom"})))

      redis.zcard("morganite:dead").should eq(1)
      redis.zcard("morganite:retry").should eq(0)
    end
  end

  describe ".beat" do
    it "refreshes an Identified session and returns RUN_SIGNAL_RUN" do
      Morganite::Jqcp::WorkerApi.hello(worker_env(%({"wid":"w-beat","queues":["default"],"concurrency":5})))

      result = Morganite::Jqcp::WorkerApi.beat(worker_env(%({"wid":"w-beat"})))
      result.should be_a(String)
      JSON.parse(result.as(String))["signal"].as_s.should eq("RUN_SIGNAL_RUN")
    end

    it "rejects Beat for an unknown wid" do
      result = Morganite::Jqcp::WorkerApi.beat(worker_env(%({"wid":"ghost"})))
      result.should be_a(Morganite::Jqcp::Errors::Rejection)
    end
  end
end
