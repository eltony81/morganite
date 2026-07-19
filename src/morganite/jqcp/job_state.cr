require "../job"
require "../retry"
require "../redis_connection"

module Morganite
  module Jqcp
    # JQCP Section 4.3 Job state machine. Morganite never stores this on the
    # Job record itself — it's computed from which Redis structure currently
    # holds the job (`JobIndex#location` already tracks exactly this), so
    # there's nothing to keep in sync when a job moves between structures.
    enum JobState
      Unspecified
      Scheduled
      Enqueued
      Active
      Succeeded
      Retrying
      Dead

      def to_jqcp_s : String
        "JOB_STATE_#{to_s.upcase}"
      end
    end

    QUEUE_PREFIX      = "morganite:queue:"
    PROCESSING_PREFIX = "morganite:processing:"
    SCHEDULED_KEY     = "morganite:scheduled"
    RETRY_KEY         = "morganite:retry"
    DEAD_KEY          = "morganite:dead"

    # `location` is the Redis key a job was found under (see `JobIndex`,
    # `Failures`, or a `morganite:queue:*`/`morganite:processing:*` scan).
    # `morganite:scheduled` is shared by both fresh SCHEDULED jobs and
    # RETRYING jobs waiting out their backoff (Section 4.3: "retrying is
    # functionally a scheduled sub-state") — retry_count distinguishes them.
    def self.state_for(job : Job, location : String) : JobState
      case location
      when .starts_with?(QUEUE_PREFIX)
        JobState::Enqueued
      when .starts_with?(PROCESSING_PREFIX)
        JobState::Active
      when SCHEDULED_KEY
        job.retry_count > 0 ? JobState::Retrying : JobState::Scheduled
      when RETRY_KEY
        JobState::Retrying
      when DEAD_KEY
        JobState::Dead
      else
        JobState::Unspecified
      end
    end

    # Renders a Job as the JSON shape described in Table 1 / Appendix C's
    # canonical-JSON examples (Section 5.2: normative wire encoding would be
    # binary Protocol Buffers, but this Broker only exposes the JSON mapping,
    # per Section 5.2's explicit allowance). `scheduled_at` isn't stored on
    # `Job` itself — it's the score of whichever ZSET (`morganite:scheduled`/
    # `morganite:retry`) currently holds the job — so callers that have it
    # (typically via `scheduled_at_for` below) pass it in explicitly.
    def self.job_to_json(job : Job, state : JobState, scheduled_at : Time? = nil) : JSON::Any
      JSON::Any.new({
        "jid"             => JSON::Any.new(job.jid),
        "type"            => JSON::Any.new(job.class),
        "queue"           => JSON::Any.new(job.queue),
        "args"            => JSON::Any.new(job.args),
        "createdAt"       => JSON::Any.new(Time.unix_ms((job.created_at * 1000).to_i64).to_rfc3339),
        "enqueuedAt"      => timestamp_json(job.enqueued_at),
        "scheduledAt"     => scheduled_at ? JSON::Any.new(scheduled_at.to_rfc3339) : JSON::Any.new(nil),
        "priority"        => JSON::Any.new(job.priority.to_i64),
        "retry"           => retry_policy_json(job),
        "timeoutSeconds"  => JSON::Any.new(job.timeout_seconds.to_i64),
        "maxLeaseSeconds" => JSON::Any.new(job.max_lease_seconds.to_i64),
        "state"           => JSON::Any.new(state.to_jqcp_s),
        "lastError"       => last_error_json(job),
      })
    end

    # `location` must be `SCHEDULED_KEY` or `RETRY_KEY` (a ZSET) for this to
    # return anything — a job in a LIST (queue/processing) or the DEAD ZSET
    # has no meaningful scheduled_at. A single ZSCORE lookup, fine for a
    # per-job GetJob/RetryJob/KillJob response; bulk listers (ListJobs) fetch
    # scores directly via `ZRANGE ... WITHSCORES` instead of calling this
    # once per job.
    def self.scheduled_at_for(redis : Redis::Client, job : Job, location : String) : Time?
      return nil unless location == SCHEDULED_KEY || location == RETRY_KEY

      score = redis.zscore(location, job.to_json)
      score.is_a?(Float) ? Time.unix(score.to_i64) : nil
    end

    private def self.retry_policy_json(job : Job) : JSON::Any
      JSON::Any.new({
        "max"     => JSON::Any.new(Retry.max_retries_for(job).to_i64),
        "count"   => JSON::Any.new(job.retry_count.to_i64),
        "backoff" => JSON::Any.new("BACKOFF_MODE_EXPONENTIAL"),
      })
    end

    private def self.last_error_json(job : Job) : JSON::Any
      return JSON::Any.new(nil) unless job.error_message

      JSON::Any.new({
        "errtype"   => JSON::Any.new(job.error_type),
        "message"   => JSON::Any.new(job.error_message),
        "backtrace" => JSON::Any.new((job.error_backtrace || [] of String).map { |line| JSON::Any.new(line) }),
        "failedAt"  => timestamp_json(job.failed_at),
      })
    end

    private def self.timestamp_json(epoch_seconds : Float64?) : JSON::Any
      return JSON::Any.new(nil) unless epoch_seconds

      JSON::Any.new(Time.unix_ms((epoch_seconds * 1000).to_i64).to_rfc3339)
    end
  end
end
