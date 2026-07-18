require "./job"
require "./retry"
require "./redis_connection"
require "./metrics"

module Morganite
  class Discard < Exception
  end

  module Failures
    RETRY_KEY = "morganite:retry"
    DEAD_KEY  = "morganite:dead"

    def self.handle(job : Job, error : Exception, redis : Redis::Client? = nil)
      return if error.is_a?(Discard)

      redis_client = redis || RedisConnection.new_client

      job.retry_count += 1
      job.failed_at ||= Time.utc.to_unix_f
      job.error_message = error.message
      job.error_backtrace = backtrace_for(job, error)

      if Retry.retry_job?(job)
        job.retried_at = Time.utc.to_unix_f
        Metrics.increment("jobs_retried")
        schedule_retry(redis_client, job)
      else
        Metrics.increment("jobs_dead")
        to_dead(redis_client, job)
      end
    end

    def self.schedule_retry(redis : Redis::Client, job : Job)
      redis.zadd(RETRY_KEY, Retry.next_retry_at(job).to_unix, job.to_json)
    end

    def self.to_dead(redis : Redis::Client, job : Job)
      remove(redis, RETRY_KEY, job)
      redis.zadd(DEAD_KEY, Time.utc.to_unix, job.to_json)
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

    def self.delete_retry(jid : String, redis : Redis::Client? = nil) : Bool
      redis_client = redis || RedisConnection.new_client
      job = find_by_jid(redis_client, RETRY_KEY, jid)
      return false unless job

      remove(redis_client, RETRY_KEY, job)
      true
    end

    private def self.backtrace_for(job : Job, error : Exception) : Array(String)?
      limit = backtrace_limit(job)
      return nil if limit == 0

      bt = error.backtrace? || [] of String
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
      result = redis.zrange(key, 0, -1)
      return nil unless result.is_a?(Array)

      result.each do |job_json|
        next unless job_json.is_a?(String)
        job = Job.from_json(job_json)
        return job if job.jid == jid
      end
      nil
    end

    private def self.remove(redis : Redis::Client, key : String, job : Job)
      redis.zrem(key, job.to_json)
    end
  end
end
