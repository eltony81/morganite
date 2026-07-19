require "../../spec_helper"
require "./support"

# Implements the scenarios described in
# ~/Projects/job_queue_protocol/JQCP-e2e-test-scenarios.md against the real
# WorkerApi/OperatorApi handlers and real Redis — no mocks. Two systematic
# adaptations from the document (both due to this Broker's JSON-over-HTTP
# transport, documented in docs/jqcp_conformance.md, not bugs):
#
# 1. Where the document expects a *single open Fetch stream* to receive a
#    second push later, this Broker's Fetch is a bounded-blocking poll —
#    the test calls Fetch again instead.
# 2. gRPC status codes (Sez. 5.4) become HTTP status codes + a JSON
#    "reason" field (Jqcp::Errors); assertions check Errors::Rejection#reason
#    instead of a gRPC code.
#
# Fast, deterministic backoff for retry-cycle scenarios: worker classes
# below override `retry_in` to a small fixed delay instead of the default
# formula (count**4 + 15 + jitter, ~16-74s for count=1) — exactly the
# "small backoff values in the test environment" technique the document
# itself recommends (Sez. 0, "Nota — gestione del tempo nei test”).

class JqcpE2eWorker
  include Morganite::Worker

  def perform(args)
  end

  def self.retry_in(retry_count : Int32) : Int32?
    2
  end
end

private def worker_env(body : String) : HTTP::Server::Context
  Morganite::Jqcp::SpecSupport.fake_env(body, "test-worker-token")
end

private def read_env(body : String? = nil) : HTTP::Server::Context
  Morganite::Jqcp::SpecSupport.fake_env(body, "test-read-token")
end

private def write_env(body : String) : HTTP::Server::Context
  Morganite::Jqcp::SpecSupport.fake_env(body, "test-write-token")
end

private def reference_job(extra : String = "") : String
  %({"job":{"type":"JqcpE2eWorker","queue":"default","args":[4821],"retry":{"max":5}#{extra}}})
end

private def jid_of(result) : String
  JSON.parse(result.as(String))["jid"].as_s
end

private def state_of(result) : String
  JSON.parse(result.as(String))["state"].as_s
end

private def with_retry_poller(&)
  poller = Morganite::RetryPoller.new(poll_interval: 300.milliseconds)
  spawn { poller.run }
  begin
    yield
  ensure
    poller.stop
  end
end

describe "JQCP e2e scenarios (JQCP-e2e-test-scenarios.md)" do
  describe "1. Panoramica generale (smoke test)" do
    it "enqueue -> hello -> fetch -> fail -> auto-retry -> fetch again -> operator query/control" do
      with_retry_poller do
        enq = Morganite::Jqcp::WorkerApi.enqueue(worker_env(reference_job))
        enq.should be_a(String)
        jid = jid_of(enq)
        state_of(enq).should eq("JOB_STATE_ENQUEUED")

        hello = Morganite::Jqcp::WorkerApi.hello(worker_env(%({"wid":"w1","queues":["default"],"concurrency":5})))
        hello.should be_a(String)
        JSON.parse(hello.as(String))["priorityStrategy"].should_not be_nil

        fetched = Morganite::Jqcp::WorkerApi.fetch(worker_env(%({"wid":"w1"})))
        fetched.should be_a(String)
        jid_of(fetched).should eq(jid)
        state_of(fetched).should eq("JOB_STATE_ACTIVE")

        failed = Morganite::Jqcp::WorkerApi.fail(worker_env(%({"wid":"w1","jid":"#{jid}","errtype":"Net::SMTPError","message":"boom"})))
        failed.should be_a(String)

        retrying = Morganite::Jqcp::OperatorApi.get_job(read_env(%({"jid":"#{jid}"})))
        retrying_json = JSON.parse(retrying.as(String))
        retrying_json["state"].as_s.should eq("JOB_STATE_RETRYING")
        retrying_json["retry"]["count"].as_i.should eq(1)
        retrying_json["scheduledAt"]?.should_not be_nil

        # Auto-retry: RetryPoller moves it back to ENQUEUED once the (fast,
        # test-only) 2s backoff elapses, with no further action from us.
        sleep 3.5.seconds
        re_enqueued = Morganite::Jqcp::OperatorApi.get_job(read_env(%({"jid":"#{jid}"})))
        state_of(re_enqueued).should eq("JOB_STATE_ENQUEUED")

        # Adaptation 1: new Fetch call instead of a push on the same stream.
        refetched = Morganite::Jqcp::WorkerApi.fetch(worker_env(%({"wid":"w1"})))
        jid_of(refetched).should eq(jid)
        state_of(refetched).should eq("JOB_STATE_ACTIVE")

        acked = Morganite::Jqcp::WorkerApi.ack(worker_env(%({"wid":"w1","jid":"#{jid}"})))
        acked.should be_a(String)

        workers = JSON.parse(Morganite::Jqcp::OperatorApi.list_workers(read_env).as(String))
        workers["workers"].as_a.map(&.["wid"].as_s).should contain("w1")
      end
    end
  end

  describe "2. Query read-only" do
    it "GetJob on an existing jid returns coherent state/retry/lastError" do
      enq = Morganite::Jqcp::WorkerApi.enqueue(worker_env(reference_job))
      jid = jid_of(enq)

      result = JSON.parse(Morganite::Jqcp::OperatorApi.get_job(read_env(%({"jid":"#{jid}"}))).as(String))
      result["state"].as_s.should eq("JOB_STATE_ENQUEUED")
      result["retry"]["max"].as_i.should eq(5)
    end

    it "GetJob on an unknown jid -> job_not_found" do
      result = Morganite::Jqcp::OperatorApi.get_job(read_env(%({"jid":"does-not-exist"})))
      result.should be_a(Morganite::Jqcp::Errors::Rejection)
      result.as(Morganite::Jqcp::Errors::Rejection).reason.should eq("job_not_found")
    end

    it "ListJobs(states:[DEAD]) returns only DEAD jobs, paginates with page_size 1" do
      enq1 = Morganite::Jqcp::WorkerApi.enqueue(worker_env(reference_job))
      enq2 = Morganite::Jqcp::WorkerApi.enqueue(worker_env(reference_job))
      jid1 = jid_of(enq1)
      jid2 = jid_of(enq2)
      Morganite::Jqcp::OperatorApi.kill_job(write_env(%({"jid":"#{jid1}"})))
      Morganite::Jqcp::OperatorApi.kill_job(write_env(%({"jid":"#{jid2}"})))

      all_dead = JSON.parse(Morganite::Jqcp::OperatorApi.list_jobs(read_env(%({"states":["JOB_STATE_DEAD"]}))).as(String))
      dead_jids = all_dead["jobs"].as_a.map(&.["jid"].as_s)
      dead_jids.should contain(jid1)
      dead_jids.should contain(jid2)
      all_dead["jobs"].as_a.each { |j| j["state"].as_s.should eq("JOB_STATE_DEAD") }

      page1 = JSON.parse(Morganite::Jqcp::OperatorApi.list_jobs(read_env(%({"states":["JOB_STATE_DEAD"],"pageSize":1}))).as(String))
      page1["jobs"].as_a.size.should eq(1)
      token = page1["nextPageToken"].as_s
      token.should_not eq("")

      page2 = JSON.parse(Morganite::Jqcp::OperatorApi.list_jobs(read_env(%({"states":["JOB_STATE_DEAD"],"pageSize":1,"pageToken":"#{token}"}))).as(String))
      page2["jobs"].as_a.size.should eq(1)
      page2["jobs"].as_a[0]["jid"].as_s.should_not eq(page1["jobs"].as_a[0]["jid"].as_s)
    end

    it "ListQueues reports a size coherent with actually-enqueued jobs" do
      3.times { Morganite::Jqcp::WorkerApi.enqueue(worker_env(reference_job)) }
      result = JSON.parse(Morganite::Jqcp::OperatorApi.list_queues(read_env).as(String))
      default_queue = result["queues"].as_a.find! { |queue_json| queue_json["name"].as_s == "default" }
      default_queue["size"].as_i.should eq(3)
    end

    it "GetStats counters are cumulative and non-decreasing after Ack/Fail" do
      before = JSON.parse(Morganite::Jqcp::OperatorApi.get_stats(read_env).as(String))

      enq = Morganite::Jqcp::WorkerApi.enqueue(worker_env(reference_job))
      jid = jid_of(enq)
      Morganite::Jqcp::WorkerApi.hello(worker_env(%({"wid":"w-stats","queues":["default"],"concurrency":5})))
      Morganite::Jqcp::WorkerApi.fetch(worker_env(%({"wid":"w-stats"})))
      Morganite::Jqcp::WorkerApi.ack(worker_env(%({"wid":"w-stats","jid":"#{jid}"})))

      after = JSON.parse(Morganite::Jqcp::OperatorApi.get_stats(read_env).as(String))
      after["processed"].as_i64.should be >= before["processed"].as_i64 + 1
    end
  end

  describe "3. Scenario 1 — Happy Path" do
    it "enqueue -> hello -> fetch -> ack -> job not in dead/retrying afterward" do
      enq = Morganite::Jqcp::WorkerApi.enqueue(worker_env(reference_job))
      jid = jid_of(enq)

      Morganite::Jqcp::WorkerApi.hello(worker_env(%({"wid":"w1","queues":["default"],"concurrency":5})))
      fetched = Morganite::Jqcp::WorkerApi.fetch(worker_env(%({"wid":"w1"})))
      jid_of(fetched).should eq(jid)

      acked = Morganite::Jqcp::WorkerApi.ack(worker_env(%({"wid":"w1","jid":"#{jid}"})))
      acked.should be_a(String)

      dead = JSON.parse(Morganite::Jqcp::OperatorApi.list_jobs(read_env(%({"states":["JOB_STATE_DEAD"]}))).as(String))
      dead["jobs"].as_a.map(&.["jid"].as_s).should_not contain(jid)

      retrying = JSON.parse(Morganite::Jqcp::OperatorApi.list_jobs(read_env(%({"states":["JOB_STATE_RETRYING"]}))).as(String))
      retrying["jobs"].as_a.map(&.["jid"].as_s).should_not contain(jid)
    end
  end

  describe "4. Scenario 2 — Fallimento transitorio con retry automatico" do
    it "Fail -> RETRYING (count=1) -> auto ENQUEUED after backoff -> re-fetch -> Ack, count stays 1" do
      with_retry_poller do
        enq = Morganite::Jqcp::WorkerApi.enqueue(worker_env(reference_job))
        jid = jid_of(enq)
        Morganite::Jqcp::WorkerApi.hello(worker_env(%({"wid":"w1","queues":["default"],"concurrency":5})))
        Morganite::Jqcp::WorkerApi.fetch(worker_env(%({"wid":"w1"})))

        Morganite::Jqcp::WorkerApi.fail(worker_env(%({"wid":"w1","jid":"#{jid}","errtype":"Net::SMTPError","message":"SMTP timeout"})))

        after_fail = JSON.parse(Morganite::Jqcp::OperatorApi.get_job(read_env(%({"jid":"#{jid}"}))).as(String))
        after_fail["retry"]["count"].as_i.should eq(1)
        after_fail["state"].as_s.should eq("JOB_STATE_RETRYING")

        sleep 3.5.seconds # comfortably past the 2s test-only backoff, never asserted to the millisecond

        re_enqueued = Morganite::Jqcp::OperatorApi.get_job(read_env(%({"jid":"#{jid}"})))
        state_of(re_enqueued).should eq("JOB_STATE_ENQUEUED")

        refetched = Morganite::Jqcp::WorkerApi.fetch(worker_env(%({"wid":"w1"})))
        jid_of(refetched).should eq(jid)
        state_of(refetched).should eq("JOB_STATE_ACTIVE")

        acked = Morganite::Jqcp::WorkerApi.ack(worker_env(%({"wid":"w1","jid":"#{jid}"})))
        acked.should be_a(String)

        # Regression: the RETRYING -> ENQUEUED -> ACTIVE path is not itself a
        # new Fail, so count must not have been bumped a second time. (The
        # job may already be gone — succeeded jobs aren't retained — either
        # outcome is fine; we only assert count wasn't incremented if found.)
        final = Morganite::Jqcp::OperatorApi.get_job(read_env(%({"jid":"#{jid}"})))
        JSON.parse(final)["retry"]["count"].as_i.should eq(1) if final.is_a?(String)
      end
    end
  end

  describe "5. Scenario 3 — Retry esauriti, dead-letter, retry manuale" do
    it "exhausts retry.max=2, lands on DEAD (not RETRYING) on the last failure, then RetryJob resets it" do
      enq = Morganite::Jqcp::WorkerApi.enqueue(worker_env(reference_job(%(,"retry":{"max":2}))))
      jid = jid_of(enq)
      Morganite::Jqcp::WorkerApi.hello(worker_env(%({"wid":"w1","queues":["default"],"concurrency":5})))

      # Iteration 1: count 0 -> 1, still under max=2 -> RETRYING.
      Morganite::Jqcp::WorkerApi.fetch(worker_env(%({"wid":"w1"})))
      Morganite::Jqcp::WorkerApi.fail(worker_env(%({"wid":"w1","jid":"#{jid}","message":"still failing"})))
      after1 = JSON.parse(Morganite::Jqcp::OperatorApi.get_job(read_env(%({"jid":"#{jid}"}))).as(String))
      after1["state"].as_s.should eq("JOB_STATE_RETRYING")
      after1["retry"]["count"].as_i.should eq(1)

      # Bypass the real backoff via the operator (Section 8.4 RetryJob),
      # exactly as verified manually earlier — resetCount:false preserves
      # count so this iteration still counts toward exhausting retry.max.
      Morganite::Jqcp::OperatorApi.retry_job(write_env(%({"jid":"#{jid}","resetCount":false})))

      # Iteration 2: count 1 -> 2, now >= max=2 -> DEAD directly, no further backoff.
      Morganite::Jqcp::WorkerApi.fetch(worker_env(%({"wid":"w1"})))
      Morganite::Jqcp::WorkerApi.fail(worker_env(%({"wid":"w1","jid":"#{jid}","errtype":"Net::SMTPError","message":"final failure"})))
      after2 = JSON.parse(Morganite::Jqcp::OperatorApi.get_job(read_env(%({"jid":"#{jid}"}))).as(String))
      after2["state"].as_s.should eq("JOB_STATE_DEAD")
      after2["retry"]["count"].as_i.should eq(2)
      after2["lastError"]["errtype"].as_s.should eq("Net::SMTPError")
      after2["lastError"]["message"].as_s.should eq("final failure")

      dead_list = JSON.parse(Morganite::Jqcp::OperatorApi.list_jobs(read_env(%({"states":["JOB_STATE_DEAD"]}))).as(String))
      dead_list["jobs"].as_a.map(&.["jid"].as_s).should contain(jid)

      # Manual retry by the operator, resetting count.
      retried = JSON.parse(Morganite::Jqcp::OperatorApi.retry_job(write_env(%({"jid":"#{jid}","resetCount":true}))).as(String))
      retried["state"].as_s.should eq("JOB_STATE_ENQUEUED")
      retried["retry"]["count"].as_i.should eq(0)
    end

    it "RetryJob(resetCount:false) on a DEAD job leaves retry.count unchanged" do
      enq = Morganite::Jqcp::WorkerApi.enqueue(worker_env(reference_job(%(,"retry":{"max":1}))))
      jid = jid_of(enq)
      Morganite::Jqcp::WorkerApi.hello(worker_env(%({"wid":"w1","queues":["default"],"concurrency":5})))
      Morganite::Jqcp::WorkerApi.fetch(worker_env(%({"wid":"w1"})))
      Morganite::Jqcp::WorkerApi.fail(worker_env(%({"wid":"w1","jid":"#{jid}","message":"boom"})))

      dead = JSON.parse(Morganite::Jqcp::OperatorApi.get_job(read_env(%({"jid":"#{jid}"}))).as(String))
      dead["state"].as_s.should eq("JOB_STATE_DEAD")
      count_before = dead["retry"]["count"].as_i

      retried = JSON.parse(Morganite::Jqcp::OperatorApi.retry_job(write_env(%({"jid":"#{jid}","resetCount":false}))).as(String))
      retried["retry"]["count"].as_i.should eq(count_before)
    end

    it "RetryJob on an ENQUEUED job -> invalid_state_transition" do
      enq = Morganite::Jqcp::WorkerApi.enqueue(worker_env(reference_job))
      jid = jid_of(enq)

      result = Morganite::Jqcp::OperatorApi.retry_job(write_env(%({"jid":"#{jid}"})))
      result.should be_a(Morganite::Jqcp::Errors::Rejection)
      result.as(Morganite::Jqcp::Errors::Rejection).reason.should eq("invalid_state_transition")
    end
  end

  describe "6. Scenario 4 — Crash del worker e Lease recovery" do
    it "an unresponsive w1's job is recovered by w2 after the Lease expires, without incrementing retry_count, and w1's late Ack is rejected" do
      enq = Morganite::Jqcp::WorkerApi.enqueue(worker_env(reference_job(%(,"timeoutSeconds":1))))
      jid = jid_of(enq)

      Morganite::Jqcp::WorkerApi.hello(worker_env(%({"wid":"w1","queues":["default"],"concurrency":5})))
      fetched = Morganite::Jqcp::WorkerApi.fetch(worker_env(%({"wid":"w1"})))
      jid_of(fetched).should eq(jid)

      # "Crash" w1: simply never call Ack/Fail/Beat again from that identity.
      # Before the Lease expires, w2 must NOT receive it (no double delivery
      # while the Lease is still valid).
      Morganite::Jqcp::WorkerApi.hello(worker_env(%({"wid":"w2","queues":["default"],"concurrency":5})))
      Morganite.config.jqcp_fetch_timeout_seconds = 1
      immediate = Morganite::Jqcp::WorkerApi.fetch(worker_env(%({"wid":"w2"})))
      immediate.should be_nil
      Morganite.config.jqcp_fetch_timeout_seconds = 5

      reaper = Morganite::Jqcp::LeaseReaper.new(poll_interval: 300.milliseconds)
      spawn { reaper.run }
      sleep 2.seconds
      reaper.stop

      recovered = JSON.parse(Morganite::Jqcp::OperatorApi.get_job(read_env(%({"jid":"#{jid}"}))).as(String))
      recovered["state"].as_s.should eq("JOB_STATE_ENQUEUED")
      recovered["retry"]["count"].as_i.should eq(0) # crash recovery must not consume a retry attempt

      refetched = Morganite::Jqcp::WorkerApi.fetch(worker_env(%({"wid":"w2"})))
      jid_of(refetched).should eq(jid)
      state_of(refetched).should eq("JOB_STATE_ACTIVE")

      # w1's late Ack must be rejected — its Lease no longer exists.
      late_ack = Morganite::Jqcp::WorkerApi.ack(worker_env(%({"wid":"w1","jid":"#{jid}"})))
      late_ack.should be_a(Morganite::Jqcp::Errors::Rejection)
      late_ack.as(Morganite::Jqcp::Errors::Rejection).reason.should eq("job_not_found")

      acked = Morganite::Jqcp::WorkerApi.ack(worker_env(%({"wid":"w2","jid":"#{jid}"})))
      acked.should be_a(String)
    end
  end

  describe "7. Scenario 5 — Kill di un job poison-pill" do
    it "KillJob on an ACTIVE job transitions it to DEAD immediately, revokes the Lease, and is idempotent" do
      enq = Morganite::Jqcp::WorkerApi.enqueue(worker_env(reference_job))
      jid = jid_of(enq)
      Morganite::Jqcp::WorkerApi.hello(worker_env(%({"wid":"w1","queues":["default"],"concurrency":5})))
      Morganite::Jqcp::WorkerApi.fetch(worker_env(%({"wid":"w1"})))

      workers = JSON.parse(Morganite::Jqcp::OperatorApi.list_workers(read_env).as(String))
      w1 = workers["workers"].as_a.find! { |worker_json| worker_json["wid"].as_s == "w1" }
      w1["leasedJids"].as_a.map(&.as_s).should contain(jid)

      killed = JSON.parse(Morganite::Jqcp::OperatorApi.kill_job(write_env(%({"jid":"#{jid}"}))).as(String))
      killed["state"].as_s.should eq("JOB_STATE_DEAD")

      late_ack = Morganite::Jqcp::WorkerApi.ack(worker_env(%({"wid":"w1","jid":"#{jid}"})))
      late_ack.should be_a(Morganite::Jqcp::Errors::Rejection)
      late_ack.as(Morganite::Jqcp::Errors::Rejection).reason.should eq("job_not_found")

      late_fail = Morganite::Jqcp::WorkerApi.fail(worker_env(%({"wid":"w1","jid":"#{jid}","message":"too late"})))
      late_fail.should be_a(Morganite::Jqcp::Errors::Rejection)
      late_fail.as(Morganite::Jqcp::Errors::Rejection).reason.should eq("job_not_found")

      killed_again = Morganite::Jqcp::OperatorApi.kill_job(write_env(%({"jid":"#{jid}"})))
      killed_again.should be_a(String) # idempotent no-op, still 200 OK
      JSON.parse(killed_again.as(String))["state"].as_s.should eq("JOB_STATE_DEAD")
    end

    it "KillJob on ENQUEUED transitions directly to DEAD (never through ACTIVE)" do
      enq = Morganite::Jqcp::WorkerApi.enqueue(worker_env(reference_job))
      jid = jid_of(enq)

      killed = JSON.parse(Morganite::Jqcp::OperatorApi.kill_job(write_env(%({"jid":"#{jid}"}))).as(String))
      killed["state"].as_s.should eq("JOB_STATE_DEAD")
    end

    it "KillJob on a SUCCEEDED job: documented deviation — job_not_found, not invalid_state_transition, because succeeded jobs aren't retained" do
      enq = Morganite::Jqcp::WorkerApi.enqueue(worker_env(reference_job))
      jid = jid_of(enq)
      Morganite::Jqcp::WorkerApi.hello(worker_env(%({"wid":"w1","queues":["default"],"concurrency":5})))
      Morganite::Jqcp::WorkerApi.fetch(worker_env(%({"wid":"w1"})))
      Morganite::Jqcp::WorkerApi.ack(worker_env(%({"wid":"w1","jid":"#{jid}"})))

      result = Morganite::Jqcp::OperatorApi.kill_job(write_env(%({"jid":"#{jid}"})))
      result.should be_a(Morganite::Jqcp::Errors::Rejection)
      # RFC 8.5 prescribes invalid_state_transition here; this Broker can only
      # report job_not_found since a succeeded Job leaves no trace to find
      # (Section 4.3 explicitly permits immediate discard on success).
      result.as(Morganite::Jqcp::Errors::Rejection).reason.should eq("job_not_found")
    end
  end

  describe "8. Scenario 6 — Idempotency key blocca il duplicato" do
    it "a second Enqueue with the same idempotency_key is rejected while the first is non-terminal, accepted once terminal" do
      key = "invoice-4821-monthly-#{Random.rand(1_000_000)}"
      first = Morganite::Jqcp::WorkerApi.enqueue(worker_env(reference_job(%(,"idempotencyKey":"#{key}"))))
      first.should be_a(String)
      jid1 = jid_of(first)

      duplicate = Morganite::Jqcp::WorkerApi.enqueue(worker_env(reference_job(%(,"idempotencyKey":"#{key}"))))
      duplicate.should be_a(Morganite::Jqcp::Errors::Rejection)
      duplicate.as(Morganite::Jqcp::Errors::Rejection).reason.should eq("duplicate_idempotency_key")

      all_enqueued = JSON.parse(Morganite::Jqcp::OperatorApi.list_jobs(read_env(%({"states":["JOB_STATE_ENQUEUED"]}))).as(String))
      all_enqueued["jobs"].as_a.count { |j| j["jid"].as_s != jid1 && j["args"] == JSON.parse("[4821]") }.should eq(0)

      # Bring the first Job to a terminal state (SUCCEEDED via Ack).
      Morganite::Jqcp::WorkerApi.hello(worker_env(%({"wid":"w1","queues":["default"],"concurrency":5})))
      Morganite::Jqcp::WorkerApi.fetch(worker_env(%({"wid":"w1"})))
      Morganite::Jqcp::WorkerApi.ack(worker_env(%({"wid":"w1","jid":"#{jid1}"})))

      # This Broker releases the idempotency reservation on Ack — a fresh
      # Enqueue with the same key is now accepted as a new Job (one of the
      # two RFC-permitted behaviors; documented in docs/jqcp_conformance.md).
      second = Morganite::Jqcp::WorkerApi.enqueue(worker_env(reference_job(%(,"idempotencyKey":"#{key}"))))
      second.should be_a(String)
      jid_of(second).should_not eq(jid1)
    end
  end
end
