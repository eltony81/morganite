require "../../spec_helper"
require "./support"

class JqcpOpPingWorker
  include Morganite::Worker

  def perform(args)
  end
end

private def read_env(body : String? = nil) : HTTP::Server::Context
  Morganite::Jqcp::SpecSupport.fake_env(body, "test-read-token")
end

private def write_env(body : String) : HTTP::Server::Context
  Morganite::Jqcp::SpecSupport.fake_env(body, "test-write-token")
end

private def worker_env(body : String) : HTTP::Server::Context
  Morganite::Jqcp::SpecSupport.fake_env(body, "test-worker-token")
end

private def enqueue(args_json = "[]") : String
  result = Morganite::Jqcp::WorkerApi.enqueue(worker_env(%({"job":{"type":"JqcpOpPingWorker","queue":"default","args":#{args_json}}})))
  JSON.parse(result.as(String))["jid"].as_s
end

describe Morganite::Jqcp::OperatorApi do
  describe ".list_queues / .get_queue" do
    it "reports queue size and paused state" do
      enqueue
      result = JSON.parse(Morganite::Jqcp::OperatorApi.list_queues(read_env).as(String))
      queues = result["queues"].as_a
      default_queue = queues.find! { |queue_json| queue_json["name"].as_s == "default" }
      default_queue["size"].as_i.should eq(1)
      default_queue["paused"].as_bool.should eq(false)
    end
  end

  describe ".update_queue" do
    it "pauses a queue, blocking Fetch, then resumes it" do
      Morganite::Jqcp::WorkerApi.hello(worker_env(%({"wid":"w-pause","queues":["default"],"concurrency":5})))
      enqueue

      Morganite::Jqcp::OperatorApi.update_queue(write_env(%({"queue":{"name":"default","paused":true},"updateMask":"paused"})))
      Morganite::Jqcp::QueueControl.paused?(Morganite::RedisConnection.new_client, "default").should be_true

      Morganite.config.jqcp_fetch_timeout_seconds = 1
      Morganite::Jqcp::WorkerApi.fetch(worker_env(%({"wid":"w-pause"}))).should be_nil
      Morganite.config.jqcp_fetch_timeout_seconds = 5

      Morganite::Jqcp::OperatorApi.update_queue(write_env(%({"queue":{"name":"default","paused":false},"updateMask":"paused"})))
      Morganite::Jqcp::WorkerApi.fetch(worker_env(%({"wid":"w-pause"}))).should be_a(String)
    end

    it "sets a weighted priority strategy" do
      Morganite::Jqcp::OperatorApi.update_queue(write_env(
        %({"queue":{"name":"default","priorityStrategy":{"mode":"WEIGHTED","weights":{"critical":3,"default":1}}},"updateMask":"priorityStrategy"})
      ))

      strategy = Morganite::Jqcp::QueueControl.strategy(Morganite::RedisConnection.new_client)
      strategy.mode.should eq("weighted")
      strategy.weights["critical"].should eq(3)
    end
  end

  describe ".get_job" do
    it "finds a job in any of the six states" do
      jid = enqueue

      enqueued = JSON.parse(Morganite::Jqcp::OperatorApi.get_job(read_env(%({"jid":"#{jid}"}))).as(String))
      enqueued["state"].as_s.should eq("JOB_STATE_ENQUEUED")

      Morganite::Jqcp::WorkerApi.hello(worker_env(%({"wid":"w-getjob","queues":["default"],"concurrency":5})))
      Morganite::Jqcp::WorkerApi.fetch(worker_env(%({"wid":"w-getjob"})))

      active = JSON.parse(Morganite::Jqcp::OperatorApi.get_job(read_env(%({"jid":"#{jid}"}))).as(String))
      active["state"].as_s.should eq("JOB_STATE_ACTIVE")
    end

    it "returns job_not_found for an unknown jid" do
      result = Morganite::Jqcp::OperatorApi.get_job(read_env(%({"jid":"does-not-exist"})))
      result.should be_a(Morganite::Jqcp::Errors::Rejection)
      result.as(Morganite::Jqcp::Errors::Rejection).reason.should eq("job_not_found")
    end
  end

  describe ".retry_job" do
    it "moves a dead job back to enqueued and resets retry_count by default" do
      jid = enqueue
      Morganite::Jqcp::OperatorApi.kill_job(write_env(%({"jid":"#{jid}"})))

      result = JSON.parse(Morganite::Jqcp::OperatorApi.retry_job(write_env(%({"jid":"#{jid}"}))).as(String))
      result["state"].as_s.should eq("JOB_STATE_ENQUEUED")
      result["retry"]["count"].as_i.should eq(0)
    end

    it "rejects retrying a job that is currently enqueued" do
      jid = enqueue
      result = Morganite::Jqcp::OperatorApi.retry_job(write_env(%({"jid":"#{jid}"})))
      result.should be_a(Morganite::Jqcp::Errors::Rejection)
      result.as(Morganite::Jqcp::Errors::Rejection).reason.should eq("invalid_state_transition")
    end
  end

  describe ".kill_job" do
    it "kills an active job (revokes its Lease) and is idempotent once dead" do
      Morganite::Jqcp::WorkerApi.hello(worker_env(%({"wid":"w-kill","queues":["default"],"concurrency":5})))
      jid = enqueue
      Morganite::Jqcp::WorkerApi.fetch(worker_env(%({"wid":"w-kill"})))

      first = JSON.parse(Morganite::Jqcp::OperatorApi.kill_job(write_env(%({"jid":"#{jid}"}))).as(String))
      first["state"].as_s.should eq("JOB_STATE_DEAD")
      Morganite::RedisConnection.new_client.llen("morganite:processing:w-kill").should eq(0)

      second = Morganite::Jqcp::OperatorApi.kill_job(write_env(%({"jid":"#{jid}"})))
      second.should be_a(String)
      JSON.parse(second.as(String))["state"].as_s.should eq("JOB_STATE_DEAD")
    end

    it "returns job_not_found for an unknown jid" do
      result = Morganite::Jqcp::OperatorApi.kill_job(write_env(%({"jid":"does-not-exist"})))
      result.should be_a(Morganite::Jqcp::Errors::Rejection)
    end
  end

  describe ".delete_job" do
    it "requires confirm and only deletes from dead" do
      jid = enqueue

      without_confirm = Morganite::Jqcp::OperatorApi.delete_job(write_env(%({"jid":"#{jid}"})))
      without_confirm.should be_a(Morganite::Jqcp::Errors::Rejection)

      not_dead_yet = Morganite::Jqcp::OperatorApi.delete_job(write_env(%({"jid":"#{jid}","confirm":true})))
      not_dead_yet.should be_a(Morganite::Jqcp::Errors::Rejection)
      not_dead_yet.as(Morganite::Jqcp::Errors::Rejection).reason.should eq("invalid_state_transition")

      Morganite::Jqcp::OperatorApi.kill_job(write_env(%({"jid":"#{jid}"})))
      deleted = Morganite::Jqcp::OperatorApi.delete_job(write_env(%({"jid":"#{jid}","confirm":true})))
      deleted.should be_a(String)

      Morganite::Jqcp::OperatorApi.get_job(read_env(%({"jid":"#{jid}"}))).should be_a(Morganite::Jqcp::Errors::Rejection)
    end
  end

  describe ".list_jobs" do
    it "filters by requested states" do
      enqueued_jid = enqueue
      dead_jid = enqueue
      Morganite::Jqcp::OperatorApi.kill_job(write_env(%({"jid":"#{dead_jid}"})))

      result = JSON.parse(Morganite::Jqcp::OperatorApi.list_jobs(read_env(%({"states":["JOB_STATE_DEAD"]}))).as(String))
      jids = result["jobs"].as_a.map(&.["jid"].as_s)
      jids.should contain(dead_jid)
      jids.should_not contain(enqueued_jid)
    end
  end

  describe ".list_workers" do
    it "reflects a session created via Hello, including its leased jids" do
      Morganite::Jqcp::WorkerApi.hello(worker_env(%({"wid":"w-list","queues":["default"],"concurrency":3})))
      jid = enqueue
      Morganite::Jqcp::WorkerApi.fetch(worker_env(%({"wid":"w-list"})))

      result = JSON.parse(Morganite::Jqcp::OperatorApi.list_workers(read_env).as(String))
      worker = result["workers"].as_a.find! { |worker_json| worker_json["wid"].as_s == "w-list" }
      worker["concurrency"].as_i.should eq(3)
      worker["leasedJids"].as_a.map(&.as_s).should contain(jid)
    end
  end

  describe ".get_stats" do
    it "returns cumulative counters" do
      result = JSON.parse(Morganite::Jqcp::OperatorApi.get_stats(read_env).as(String))
      result["processed"].as_i64.should be >= 0
      result["failed"].as_i64.should be >= 0
      result["dead"].as_i64.should be >= 0
    end
  end
end
