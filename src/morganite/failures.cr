require "./job"
require "./retry"
require "./redis_connection"
require "./metrics"
require "./logger"
require "./job_index"

module Morganite
  class Discard < Exception
  end

  module Failures
    RETRY_KEY     = "morganite:retry"
    DEAD_KEY      = "morganite:dead"
    SCHEDULED_KEY = "morganite:scheduled"

    def self.handle(job : Job, error : Exception, redis : Redis::Client? = nil)
      return if error.is_a?(Discard)

      record_failure(job, error.message, error.class.name, error.backtrace?)
      transition_after_failure(job, redis || RedisConnection.new_client)
    end

    # JQCP Section 7.5/8.3 (Fail RPC): failure details are reported by an
    # external Worker via JSON (errtype/message/backtrace), not raised as a
    # Crystal Exception — same retry/dead-lettering logic as `handle`
    # otherwise, including the job's own backtrace-capture policy
    # (Section 4.2's `backtrace` sidekiq_options field still applies to a
    # reported backtrace exactly as it would to a raised one).
    def self.handle_external(job : Job, errtype : String?, message : String?, backtrace : Array(String)?, redis : Redis::Client? = nil)
      record_failure(job, message, errtype, backtrace)
      transition_after_failure(job, redis || RedisConnection.new_client)
    end

    private def self.record_failure(job : Job, message : String?, error_type : String?, raw_backtrace : Array(String)?)
      job.retry_count += 1
      job.failed_at ||= Time.utc.to_unix_f
      job.error_message = message
      job.error_type = error_type
      job.error_backtrace = truncate_backtrace(job, raw_backtrace)
    end

    private def self.transition_after_failure(job : Job, redis_client : Redis::Client)
      log = Logger.context(jid: job.jid)

      if Retry.retry_job?(job)
        job.retried_at = Time.utc.to_unix_f
        Metrics.increment("jobs_retried")
        next_retry_at = schedule_retry(redis_client, job)
        log.info("job #{job.class} scheduled for retry #{job.retry_count}/#{Retry.max_retries_for(job)} at #{next_retry_at}")
      else
        Metrics.increment("jobs_dead")
        if job.dead?
          to_dead(redis_client, job)
          log.warn("job #{job.class} moved to dead queue after #{job.retry_count} attempts")
        else
          log.warn("job #{job.class} discarded after #{job.retry_count} attempts (dead: false)")
        end
      end
    end

    def self.schedule_retry(redis : Redis::Client, job : Job) : Time
      next_retry_at = Retry.next_retry_at(job)
      redis.zadd(RETRY_KEY, next_retry_at.to_unix, job.to_json)
      JobIndex.set(redis, RETRY_KEY, job)
      next_retry_at
    end

    def self.to_dead(redis : Redis::Client, job : Job)
      remove(redis, RETRY_KEY, job)
      redis.zadd(DEAD_KEY, Time.utc.to_unix, job.to_json)
      JobIndex.set(redis, DEAD_KEY, job)
      trim_dead(redis)
    end

    def self.trim_dead(redis : Redis::Client)
      config = Morganite.config

      unless config.dead_timeout_in_seconds == 0
        cutoff = Time.utc - config.dead_timeout_in_seconds.seconds
        expired = redis.zrangebyscore(DEAD_KEY, "-inf", cutoff.to_unix.to_s)
        deindex(redis, expired)
        redis.zremrangebyscore(DEAD_KEY, "-inf", cutoff.to_unix.to_s)
      end

      max_jobs = config.dead_max_jobs
      if max_jobs > 0
        dead_count = redis.zcard(DEAD_KEY)
        if dead_count.is_a?(Int) && dead_count > max_jobs
          excess = redis.zrange(DEAD_KEY, 0, dead_count - max_jobs - 1)
          deindex(redis, excess)
          redis.zremrangebyrank(DEAD_KEY, 0, dead_count - max_jobs - 1)
        end
      end
    end

    def self.retry_dead(jid : String, redis : Redis::Client? = nil) : Bool
      redis_client = redis || RedisConnection.new_client
      job = find_by_jid(redis_client, DEAD_KEY, jid)
      return false unless job

      remove(redis_client, DEAD_KEY, job)
      job.retry_count = 0
      job.failed_at = nil
      job.error_message = nil
      job.error_backtrace = nil
      job.retried_at = nil
      redis_client.lpush(job.queue_key, job.to_json)
      true
    end

    def self.delete_dead(jid : String, redis : Redis::Client? = nil) : Bool
      redis_client = redis || RedisConnection.new_client
      job = find_by_jid(redis_client, DEAD_KEY, jid)
      return false unless job

      remove(redis_client, DEAD_KEY, job)
      true
    end

    # Moves a job waiting in the retry set straight back onto its queue,
    # instead of waiting for RetryPoller to pick it up at its scheduled time.
    def self.retry_now(jid : String, redis : Redis::Client? = nil) : Bool
      redis_client = redis || RedisConnection.new_client
      job = find_by_jid(redis_client, RETRY_KEY, jid)
      return false unless job

      remove(redis_client, RETRY_KEY, job)
      redis_client.lpush(job.queue_key, job.to_json)
      true
    end

    def self.delete_retry(jid : String, redis : Redis::Client? = nil) : Bool
      redis_client = redis || RedisConnection.new_client
      job = find_by_jid(redis_client, RETRY_KEY, jid)
      return false unless job

      remove(redis_client, RETRY_KEY, job)
      true
    end

    def self.delete_scheduled(jid : String, redis : Redis::Client? = nil) : Bool
      redis_client = redis || RedisConnection.new_client
      job = find_by_jid(redis_client, SCHEDULED_KEY, jid)
      return false unless job

      remove(redis_client, SCHEDULED_KEY, job)
      true
    end

    private def self.truncate_backtrace(job : Job, backtrace : Array(String)?) : Array(String)?
      limit = backtrace_limit(job)
      return nil if limit == 0

      bt = backtrace || [] of String
      limit.nil? ? bt : bt.first(limit)
    end

    private def self.backtrace_limit(job : Job) : Int32?
      case job.backtrace
      when true
        nil
      when false
        0
      when Int32
        job.backtrace.as(Int32)
      else
        # Default: capture a reasonable backtrace
        nil
      end
    end

    private def self.find_by_jid(redis : Redis::Client, key : String, jid : String) : Job?
      JobIndex.find_in(redis, key, jid) || find_by_jid_scan(redis, key, jid)
    end

    private def self.find_by_jid_scan(redis : Redis::Client, key : String, jid : String) : Job?
      result = redis.zrange(key, 0, -1)
      return nil unless result.is_a?(Array)

      result.each do |job_json|
        next unless job_json.is_a?(String)
        job = Job.from_json(job_json)
        return job if job.jid == jid
      end
      nil
    end

    private def self.deindex(redis : Redis::Client, job_jsons)
      return unless job_jsons.is_a?(Array)

      jobs = job_jsons.compact_map do |item|
        next unless item.is_a?(String)
        begin
          Job.from_json(item)
        rescue ex : JSON::ParseException
          nil
        end
      end
      JobIndex.delete_all(redis, jobs)
    end

    private def self.remove(redis : Redis::Client, key : String, job : Job)
      redis.zrem(key, job.to_json)
      JobIndex.delete(redis, job.jid)
    end
  end
end
