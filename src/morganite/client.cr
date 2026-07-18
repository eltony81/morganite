require "./job"
require "./redis_connection"

module Morganite
  module Client
    def self.enqueue(worker_name : String, args : Array(JSON::Any), queue : String = Morganite.config.queue) : Job
      job = build_job(worker_name, args, queue)
      Morganite.pool.with do |redis|
        redis.lpush(job.queue_key, job.to_json)
      end
      job
    end

    def self.schedule(worker_name : String, time : Time, args : Array(JSON::Any), queue : String = Morganite.config.queue) : Job
      job = build_job(worker_name, args, queue)
      Morganite.pool.with do |redis|
        redis.zadd("morganite:scheduled", time.to_unix, job.to_json)
      end
      job
    end

    def self.retry_dead(jid : String) : Bool
      Failures.retry_dead(jid)
    end

    def self.delete_dead(jid : String) : Bool
      Failures.delete_dead(jid)
    end

    def self.delete_retry(jid : String) : Bool
      Failures.delete_retry(jid)
    end

    private def self.build_job(worker_name, args, queue)
      Job.new(
        class: worker_name,
        args: args,
        queue: queue,
        enqueued_at: Time.utc.to_unix_f
      )
    end
  end
end
