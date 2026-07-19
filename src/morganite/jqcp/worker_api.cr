require "json"
require "kemal"
require "../job"
require "../client"
require "../failures"
require "../retry"
require "../metrics"
require "../redis_connection"
require "../logger"
require "./auth"
require "./errors"
require "./job_state"
require "./worker_session"
require "./queue_control"
require "./idempotency"
require "./lease"

module Morganite
  module Jqcp
    # JQCP Section 7: JobWorker service (Hello/Enqueue/Fetch/Ack/Fail/Beat),
    # exposed as JSON-over-HTTP under /jqcp/v1/worker/ (see
    # docs/jqcp_conformance.md for why this isn't real gRPC). Route blocks
    # stay thin: `halt` is a Kemal macro that expands to a bare `next`, so
    # it only works called directly inside a route block, never from a
    # helper method — every handler below therefore returns
    # `String | Errors::Rejection` and the route block itself decides
    # whether to `halt` or return the body as-is.
    module WorkerApi
      def self.setup_routes
        post "/jqcp/v1/worker/hello" do |env|
          reject_unless_worker_authorized(env)
          respond(env, hello(env))
        end

        post "/jqcp/v1/worker/enqueue" do |env|
          reject_unless_worker_authorized(env)
          respond(env, enqueue(env))
        end

        post "/jqcp/v1/worker/fetch" do |env|
          reject_unless_worker_authorized(env)
          result = fetch(env)
          if result.is_a?(Errors::Rejection)
            halt env, status_code: Errors.status_for(result.reason), response: Errors.body(result.reason, result.metadata)
          elsif result.nil?
            env.response.status_code = 204
            ""
          else
            env.response.content_type = "application/json"
            result
          end
        end

        post "/jqcp/v1/worker/ack" do |env|
          reject_unless_worker_authorized(env)
          respond(env, ack(env))
        end

        post "/jqcp/v1/worker/fail" do |env|
          reject_unless_worker_authorized(env)
          respond(env, fail(env))
        end

        post "/jqcp/v1/worker/beat" do |env|
          reject_unless_worker_authorized(env)
          respond(env, beat(env))
        end
      end

      macro reject_unless_worker_authorized(env)
        unless Auth.authorized?({{env}}, Auth::Scope::Worker)
          halt {{env}}, status_code: Errors.status_for("unauthorized"), response: Errors.body("unauthorized")
        end
      end

      macro respond(env, result)
        %result = {{result}}
        if %result.is_a?(Errors::Rejection)
          halt {{env}}, status_code: Errors.status_for(%result.reason), response: Errors.body(%result.reason, %result.metadata)
        end
        {{env}}.response.content_type = "application/json"
        %result
      end

      # Section 7.1.
      def self.hello(env) : String | Errors::Rejection
        body = parse_json_body(env)
        return Errors::Rejection.new("invalid_job") unless body

        wid = body["wid"]?.try(&.as_s?)
        return Errors::Rejection.new("invalid_job") if wid.nil? || wid.empty?

        queues_field = body["queues"]?.try(&.as_a?)
        queues = queues_field ? queues_field.compact_map(&.as_s?) : [] of String
        concurrency = body["concurrency"]?.try(&.as_i?) || 1

        Morganite.pool.with do |redis|
          WorkerSession.hello(redis, wid, queues, concurrency)
          strategy = QueueControl.strategy(redis)
          {
            "priorityStrategy" => {
              "mode"    => strategy.mode.upcase,
              "weights" => strategy.weights,
            },
            "recommendedBeatIntervalSeconds" => 15,
          }.to_json
        end
      end

      private record EnqueueParams,
        type : String,
        args : Array(JSON::Any),
        queue : String,
        priority : Int32,
        timeout_seconds : UInt32,
        idempotency_key : String?,
        jid : String?,
        max_retries : Int32?,
        scheduled_at : Time?

      # Section 7.2. Also covers Table 1's `scheduled_at`: a future
      # scheduled_at routes through `Client.schedule` (JQCP has no separate
      # "ScheduleJob" RPC — SCHEDULED is just Enqueue with that field set).
      def self.enqueue(env) : String | Errors::Rejection
        body = parse_json_body(env)
        return Errors::Rejection.new("invalid_job") unless body

        job_field = body["job"]?
        return Errors::Rejection.new("invalid_job") unless job_field

        params = parse_enqueue_params(job_field)
        return Errors::Rejection.new("invalid_job") unless params

        job = if scheduled_at = params.scheduled_at
                Client.schedule(
                  params.type, scheduled_at, params.args, params.queue,
                  retry: params.max_retries || true,
                  priority: params.priority, timeout_seconds: params.timeout_seconds,
                  idempotency_key: params.idempotency_key, jid: params.jid
                )
              else
                Client.enqueue(
                  params.type, params.args, params.queue,
                  retry: params.max_retries || true,
                  priority: params.priority, timeout_seconds: params.timeout_seconds,
                  idempotency_key: params.idempotency_key, jid: params.jid
                )
              end

        unless job
          return Errors::Rejection.new("duplicate_idempotency_key", {"idempotency_key" => params.idempotency_key || ""})
        end

        state = params.scheduled_at ? JobState::Scheduled : JobState::Enqueued
        Jqcp.job_to_json(job, state, params.scheduled_at).to_json
      end

      private def self.parse_enqueue_params(job_field : JSON::Any) : EnqueueParams?
        type = job_field["type"]?.try(&.as_s?)
        return nil if type.nil? || type.empty?

        args_field = job_field["args"]?.try(&.as_a?)
        return nil unless args_field

        retry_field = job_field["retry"]?
        max_retries = retry_field ? retry_field["max"]?.try(&.as_i?) : nil

        EnqueueParams.new(
          type: type,
          args: args_field,
          queue: job_field["queue"]?.try(&.as_s?) || Morganite.config.queue,
          priority: job_field["priority"]?.try(&.as_i?) || 0,
          timeout_seconds: (job_field["timeoutSeconds"]?.try(&.as_i?) || 0).to_u32,
          idempotency_key: job_field["idempotencyKey"]?.try(&.as_s?),
          jid: job_field["jid"]?.try(&.as_s?),
          max_retries: max_retries,
          scheduled_at: parse_scheduled_at(job_field)
        )
      end

      # Section 7.3 (non-streaming fallback — see docs/jqcp_conformance.md):
      # a single bounded-blocking poll, budgeted by
      # `Morganite.config.jqcp_fetch_timeout_seconds`. No Job became
      # eligible within the budget -> nil (204, caller polls again).
      def self.fetch(env) : String | Errors::Rejection | Nil
        body = parse_json_body(env)
        return Errors::Rejection.new("invalid_job") unless body

        wid = body["wid"]?.try(&.as_s?)
        return Errors::Rejection.new("invalid_job") if wid.nil? || wid.empty?

        Morganite.pool.with do |redis|
          next Errors::Rejection.new("unauthorized") unless WorkerSession.identified?(redis, wid)

          job = fetch_one(redis, wid)
          job ? Jqcp.job_to_json(job, JobState::Active).to_json : nil
        end
      end

      # Section 7.4.
      def self.ack(env) : String | Errors::Rejection
        body = parse_json_body(env)
        return Errors::Rejection.new("invalid_job") unless body

        wid = body["wid"]?.try(&.as_s?)
        jid = body["jid"]?.try(&.as_s?)
        return Errors::Rejection.new("invalid_job") unless wid && jid

        Morganite.pool.with do |redis|
          job = Lease.find(redis, wid, jid)
          next Errors::Rejection.new("job_not_found", {"jid" => jid}) unless job

          Lease.release(redis, wid, job)
          Idempotency.release(redis, job)
          Metrics.increment("jobs_processed")
          "{}"
        end
      end

      # Section 7.5.
      def self.fail(env) : String | Errors::Rejection
        body = parse_json_body(env)
        return Errors::Rejection.new("invalid_job") unless body

        wid = body["wid"]?.try(&.as_s?)
        jid = body["jid"]?.try(&.as_s?)
        return Errors::Rejection.new("invalid_job") unless wid && jid

        errtype = body["errtype"]?.try(&.as_s?)
        message = body["message"]?.try(&.as_s?)
        backtrace_field = body["backtrace"]?.try(&.as_a?)
        backtrace = backtrace_field ? backtrace_field.compact_map(&.as_s?) : nil

        Morganite.pool.with do |redis|
          job = Lease.find(redis, wid, jid)
          next Errors::Rejection.new("job_not_found", {"jid" => jid}) unless job

          Lease.release(redis, wid, job)
          Failures.handle_external(job, errtype, message, backtrace, redis)
          Idempotency.release(redis, job) unless Retry.retry_job?(job)
          "{}"
        end
      end

      # Section 7.6.
      def self.beat(env) : String | Errors::Rejection
        body = parse_json_body(env)
        return Errors::Rejection.new("invalid_job") unless body

        wid = body["wid"]?.try(&.as_s?)
        return Errors::Rejection.new("invalid_job") if wid.nil? || wid.empty?

        Morganite.pool.with do |redis|
          session = WorkerSession.beat(redis, wid)
          next Errors::Rejection.new("unauthorized") unless session

          {"signal" => "RUN_SIGNAL_RUN"}.to_json
        end
      end

      private def self.fetch_one(redis : Redis::Client, wid : String) : Job?
        session = WorkerSession.find(redis, wid)
        return nil unless session

        queue_keys = QueueControl.select_queue_keys(redis, session.queues)
        return nil if queue_keys.empty?

        processing_key = Lease.processing_key(wid)
        deadline = Time.instant + Morganite.config.jqcp_fetch_timeout_seconds.seconds

        while Time.instant < deadline
          queue_keys.each do |queue_key|
            result = redis.brpoplpush(queue_key, processing_key, timeout: 1)
            if result.is_a?(String)
              job = Job.from_json(result)
              Lease.track(redis, job)
              return job
            end
            break if Time.instant >= deadline
          end
        end

        nil
      end

      # Section 4.2's `scheduled_at`: nil if absent, already-past, or
      # unparseable (treated as "enqueue immediately" rather than rejecting
      # the whole request over a malformed optional field).
      private def self.parse_scheduled_at(job_field : JSON::Any) : Time?
        raw = job_field["scheduledAt"]?.try(&.as_s?)
        return nil unless raw

        parsed = Time.parse_rfc3339(raw) rescue nil
        parsed && parsed > Time.utc ? parsed : nil
      end

      private def self.parse_json_body(env) : JSON::Any?
        io = env.request.body
        return nil unless io

        JSON.parse(io.gets_to_end)
      rescue JSON::ParseException
        nil
      end
    end
  end
end
