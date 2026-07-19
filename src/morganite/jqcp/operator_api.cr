require "json"
require "kemal"
require "../job"
require "../failures"
require "../metrics"
require "../redis_connection"
require "./auth"
require "./errors"
require "./job_state"
require "./queue_control"
require "./worker_session"
require "./lease"

module Morganite
  module Jqcp
    # JQCP Section 9: JobOperator service, exposed as JSON-over-HTTP under
    # /jqcp/v1/operator/ — same `halt`-only-in-route-blocks constraint and
    # `String | Errors::Rejection` handler pattern as `WorkerApi` (see its
    # top comment). Read-only RPCs require operator:read; mutating RPCs
    # (UpdateQueue, RetryJob, KillJob, DeleteJob) require operator:write.
    module OperatorApi
      def self.setup_routes
        get "/jqcp/v1/operator/list_queues" do |env|
          reject_unless_authorized(env, Auth::Scope::OperatorRead)
          respond(env, list_queues(env))
        end

        post "/jqcp/v1/operator/get_queue" do |env|
          reject_unless_authorized(env, Auth::Scope::OperatorRead)
          respond(env, get_queue(env))
        end

        post "/jqcp/v1/operator/update_queue" do |env|
          reject_unless_authorized(env, Auth::Scope::OperatorWrite)
          respond(env, update_queue(env))
        end

        post "/jqcp/v1/operator/get_job" do |env|
          reject_unless_authorized(env, Auth::Scope::OperatorRead)
          respond(env, get_job(env))
        end

        post "/jqcp/v1/operator/retry_job" do |env|
          reject_unless_authorized(env, Auth::Scope::OperatorWrite)
          respond(env, retry_job(env))
        end

        post "/jqcp/v1/operator/kill_job" do |env|
          reject_unless_authorized(env, Auth::Scope::OperatorWrite)
          respond(env, kill_job(env))
        end

        post "/jqcp/v1/operator/delete_job" do |env|
          reject_unless_authorized(env, Auth::Scope::OperatorWrite)
          respond(env, delete_job(env))
        end

        post "/jqcp/v1/operator/list_jobs" do |env|
          reject_unless_authorized(env, Auth::Scope::OperatorRead)
          respond(env, list_jobs(env))
        end

        get "/jqcp/v1/operator/list_workers" do |env|
          reject_unless_authorized(env, Auth::Scope::OperatorRead)
          respond(env, list_workers(env))
        end

        get "/jqcp/v1/operator/get_stats" do |env|
          reject_unless_authorized(env, Auth::Scope::OperatorRead)
          respond(env, get_stats(env))
        end
      end

      macro reject_unless_authorized(env, scope)
        unless Auth.authorized?({{env}}, {{scope}})
          halt {{env}}, status_code: Errors.status_for("forbidden"), response: Errors.body("forbidden")
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

      # Section 9.1.
      def self.list_queues(env) : String | Errors::Rejection
        Morganite.pool.with do |redis|
          strategy = QueueControl.strategy(redis)
          queues = queue_names(redis).map { |name| queue_json(redis, name, strategy) }
          {"queues" => queues}.to_json
        end
      end

      # Section 9.2. Any name is a valid (if possibly empty/never-used)
      # Queue in Morganite's model — queues aren't pre-declared, they come
      # into existence on first Enqueue — so this never 404s.
      def self.get_queue(env) : String | Errors::Rejection
        body = parse_json_body(env)
        return Errors::Rejection.new("invalid_job") unless body

        name = body["name"]?.try(&.as_s?)
        return Errors::Rejection.new("invalid_job") if name.nil? || name.empty?

        Morganite.pool.with do |redis|
          queue_json(redis, name, QueueControl.strategy(redis)).to_json
        end
      end

      # Section 9.3.
      def self.update_queue(env) : String | Errors::Rejection
        body = parse_json_body(env)
        return Errors::Rejection.new("invalid_job") unless body

        queue_field = body["queue"]?
        return Errors::Rejection.new("invalid_job") unless queue_field

        name = queue_field["name"]?.try(&.as_s?)
        return Errors::Rejection.new("invalid_job") if name.nil? || name.empty?

        mask = (body["updateMask"]?.try(&.as_s?) || "").split(',').map(&.strip)

        Morganite.pool.with do |redis|
          apply_paused_update(redis, name, queue_field) if mask.includes?("paused")
          apply_strategy_update(redis, queue_field) if mask.includes?("priorityStrategy")
          queue_json(redis, name, QueueControl.strategy(redis)).to_json
        end
      end

      # Section 9.4.
      def self.get_job(env) : String | Errors::Rejection
        body = parse_json_body(env)
        return Errors::Rejection.new("invalid_job") unless body

        jid = body["jid"]?.try(&.as_s?)
        return Errors::Rejection.new("invalid_job") if jid.nil? || jid.empty?

        Morganite.pool.with do |redis|
          found = Failures.find_any_state(redis, jid)
          next Errors::Rejection.new("job_not_found", {"jid" => jid}) unless found

          job, location = found
          scheduled_at = Jqcp.scheduled_at_for(redis, job, location)
          Jqcp.job_to_json(job, Jqcp.state_for(job, location), scheduled_at).to_json
        end
      end

      # Section 9.5 / Section 8.4.
      def self.retry_job(env) : String | Errors::Rejection
        body = parse_json_body(env)
        return Errors::Rejection.new("invalid_job") unless body

        jid = body["jid"]?.try(&.as_s?)
        return Errors::Rejection.new("invalid_job") if jid.nil? || jid.empty?

        reset_count = body["resetCount"]?.try(&.as_bool?)
        reset_count = true if reset_count.nil?

        Morganite.pool.with do |redis|
          job = Failures.jqcp_retry(jid, reset_count, redis)
          next Errors::Rejection.new("invalid_state_transition", {"jid" => jid}) unless job

          Jqcp.job_to_json(job, JobState::Enqueued).to_json
        end
      end

      # Section 9.6 / Section 8.5.
      def self.kill_job(env) : String | Errors::Rejection
        body = parse_json_body(env)
        return Errors::Rejection.new("invalid_job") unless body

        jid = body["jid"]?.try(&.as_s?)
        return Errors::Rejection.new("invalid_job") if jid.nil? || jid.empty?

        Morganite.pool.with do |redis|
          job = Failures.kill(jid, redis)
          next Errors::Rejection.new("job_not_found", {"jid" => jid}) unless job

          Jqcp.job_to_json(job, JobState::Dead).to_json
        end
      end

      # Section 9.7 / Section 8.6.
      def self.delete_job(env) : String | Errors::Rejection
        body = parse_json_body(env)
        return Errors::Rejection.new("invalid_job") unless body

        jid = body["jid"]?.try(&.as_s?)
        return Errors::Rejection.new("invalid_job") if jid.nil? || jid.empty?
        return Errors::Rejection.new("invalid_job", {"detail" => "confirm must be true"}) unless body["confirm"]?.try(&.as_bool?)

        Morganite.pool.with do |redis|
          found = Failures.find_any_state(redis, jid)
          next Errors::Rejection.new("job_not_found", {"jid" => jid}) unless found

          _, location = found
          next Errors::Rejection.new("invalid_state_transition", {"jid" => jid}) unless location == Failures::DEAD_KEY

          Failures.delete_dead(jid, redis)
          "{}"
        end
      end

      # Section 9.8.
      def self.list_jobs(env) : String | Errors::Rejection
        body = parse_json_body(env)
        return Errors::Rejection.new("invalid_job") unless body

        states = requested_states(body)
        page_size = body["pageSize"]?.try(&.as_i?) || 50
        offset = body["pageToken"]?.try(&.as_s?).try(&.to_i?) || 0

        Morganite.pool.with do |redis|
          all_jobs = states.flat_map { |state| jobs_for_state(redis, state) }
          page = all_jobs.skip(offset).first(page_size)
          next_token = offset + page.size < all_jobs.size ? (offset + page.size).to_s : ""

          {
            "jobs"          => page.map { |job, state, scheduled_at| Jqcp.job_to_json(job, state, scheduled_at) },
            "nextPageToken" => next_token,
          }.to_json
        end
      end

      # Section 9.9.
      def self.list_workers(env) : String | Errors::Rejection
        Morganite.pool.with do |redis|
          workers = WorkerSession.all(redis).map { |wid, session| worker_json(redis, wid, session) }
          {"workers" => workers}.to_json
        end
      end

      # Section 9.10.
      def self.get_stats(env) : String | Errors::Rejection
        {
          "processed" => Metrics.counter("jobs_processed"),
          "failed"    => Metrics.counter("jobs_failed"),
          "dead"      => Metrics.counter("jobs_dead"),
        }.to_json
      end

      private def self.queue_names(redis : Redis::Client) : Array(String)
        RedisConnection.scan_keys(redis, "#{QUEUE_PREFIX}*").compact_map do |key|
          key.ends_with?(":paused") ? nil : key.sub(QUEUE_PREFIX, "")
        end
      end

      private def self.queue_json(redis : Redis::Client, name : String, strategy : QueueControl::Strategy)
        size = redis.llen("#{QUEUE_PREFIX}#{name}")
        {
          "name"             => name,
          "size"             => size.is_a?(Int) ? size.to_i64 : 0_i64,
          "paused"           => QueueControl.paused?(redis, name),
          "priorityStrategy" => {"mode" => strategy.mode.upcase, "weights" => strategy.weights},
        }
      end

      private def self.apply_paused_update(redis : Redis::Client, name : String, queue_field : JSON::Any)
        paused = queue_field["paused"]?.try(&.as_bool?)
        return if paused.nil?

        paused ? QueueControl.pause(redis, name) : QueueControl.resume(redis, name)
      end

      private def self.apply_strategy_update(redis : Redis::Client, queue_field : JSON::Any)
        strategy_field = queue_field["priorityStrategy"]?
        return unless strategy_field

        mode = (strategy_field["mode"]?.try(&.as_s?) || "STRICT").downcase
        weights_field = strategy_field["weights"]?.try(&.as_h?)
        weights = weights_field ? weights_field.transform_values { |v| v.as_i? || 1 } : {} of String => Int32
        QueueControl.set_strategy(redis, mode, weights)
      end

      private def self.requested_states(body : JSON::Any) : Array(JobState)
        states_field = body["states"]?.try(&.as_a?)
        return JobState.values.reject(&.unspecified?) unless states_field

        parsed = states_field.compact_map { |state_field| parse_job_state(state_field.as_s?) }
        parsed.empty? ? JobState.values.reject(&.unspecified?) : parsed
      end

      private def self.parse_job_state(raw : String?) : JobState?
        return nil unless raw

        JobState.parse?(raw.sub("JOB_STATE_", ""))
      end

      private def self.jobs_for_state(redis : Redis::Client, state : JobState) : Array({Job, JobState, Time?})
        result = [] of {Job, JobState, Time?}

        case state
        when JobState::Enqueued
          scan_lists(redis, "#{QUEUE_PREFIX}*").each { |job| result << {job, JobState::Enqueued, nil} }
        when JobState::Active
          scan_lists(redis, "#{PROCESSING_PREFIX}*").each { |job| result << {job, JobState::Active, nil} }
        when JobState::Scheduled
          zset_jobs(redis, SCHEDULED_KEY).select { |job, _| job.retry_count == 0 }
            .each { |job, scheduled_at| result << {job, JobState::Scheduled, scheduled_at} }
        when JobState::Retrying
          scheduled_retries = zset_jobs(redis, SCHEDULED_KEY).select { |job, _| job.retry_count > 0 }
          (scheduled_retries + zset_jobs(redis, RETRY_KEY)).each { |job, scheduled_at| result << {job, JobState::Retrying, scheduled_at} }
        when JobState::Dead
          zset_jobs(redis, DEAD_KEY).each { |job, _| result << {job, JobState::Dead, nil} }
        end

        result
      end

      private def self.scan_lists(redis : Redis::Client, pattern : String) : Array(Job)
        RedisConnection.scan_keys(redis, pattern).reject(&.ends_with?(":paused")).flat_map do |key|
          result = redis.lrange(key, 0, -1)
          next [] of Job unless result.is_a?(Array)

          result.compact_map { |item| item.is_a?(String) ? (Job.from_json(item) rescue nil) : nil }
        end
      end

      # WITHSCORES in one round trip rather than a ZSCORE per job — the
      # score is each ZSET's activation/resumption timestamp
      # (scheduled_at, Section 4.2), needed by ListJobs for SCHEDULED/RETRYING.
      private def self.zset_jobs(redis : Redis::Client, key : String) : Array({Job, Time})
        result = redis.zrange(key, 0, -1, with_scores: true)
        return [] of {Job, Time} unless result.is_a?(Array)

        pairs = [] of {Job, Time}
        result.each_slice(2) do |pair|
          member, score = pair
          next unless member.is_a?(String) && score.is_a?(String)
          job = Job.from_json(member) rescue next
          pairs << {job, Time.unix(score.to_f64.to_i64)}
        end
        pairs
      end

      private def self.worker_json(redis : Redis::Client, wid : String, session : WorkerSession::Session)
        result = redis.lrange(Lease.processing_key(wid), 0, -1)
        leased_jids = result.is_a?(Array) ? result.compact_map { |item| item.is_a?(String) ? (Job.from_json(item).jid rescue nil) : nil } : [] of String

        {
          "wid"          => wid,
          "queues"       => session.queues,
          "concurrency"  => session.concurrency,
          "sessionState" => session.state.upcase,
          "lastBeat"     => Time.unix_ms((session.last_beat * 1000).to_i64).to_rfc3339,
          "leasedJids"   => leased_jids,
        }
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
