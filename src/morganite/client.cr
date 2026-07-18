require "./job"
require "./redis_connection"
require "./client_middleware"
require "./unique_jobs"

module Morganite
  module Client
    def self.enqueue(
      worker_name : String,
      args : Array(JSON::Any),
      queue : String = Morganite.config.queue,
      unique : String? = nil,
      unique_for : Int32 = 300,
    ) : Job?
      job = build_job(worker_name, args, queue, unique, unique_for)

      if job.unique && job.unique != "while_executing"
        acquired = false
        Morganite.pool.with do |redis|
          ttl = job.unique == "until_expired" ? job.unique_for : nil
          acquired = UniqueJobs.lock(job, ttl: ttl, redis: redis)
          if acquired
            ClientMiddleware.invoke(job, -> {
              redis.lpush(job.queue_key, job.to_json)
              nil
            })
          end
        end
        return nil unless acquired
      else
        ClientMiddleware.invoke(job, -> {
          Morganite.pool.with do |redis|
            redis.lpush(job.queue_key, job.to_json)
          end
          nil
        })
      end

      job
    end

    def self.schedule(
      worker_name : String,
      time : Time,
      args : Array(JSON::Any),
      queue : String = Morganite.config.queue,
      unique : String? = nil,
      unique_for : Int32 = 300,
    ) : Job?
      job = build_job(worker_name, args, queue, unique, unique_for)

      if job.unique && job.unique != "while_executing"
        acquired = false
        Morganite.pool.with do |redis|
          ttl = job.unique == "until_expired" ? job.unique_for : nil
          acquired = UniqueJobs.lock(job, ttl: ttl, redis: redis)
          if acquired
            ClientMiddleware.invoke(job, -> {
              redis.zadd("morganite:scheduled", time.to_unix, job.to_json)
              nil
            })
          end
        end
        return nil unless acquired
      else
        ClientMiddleware.invoke(job, -> {
          Morganite.pool.with do |redis|
            redis.zadd("morganite:scheduled", time.to_unix, job.to_json)
          end
          nil
        })
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

    private def self.build_job(worker_name, args, queue, unique = nil, unique_for = 300)
      Job.new(
        class: worker_name,
        args: args,
        queue: queue,
        unique: unique,
        unique_for: unique_for,
        enqueued_at: Time.utc.to_unix_f
      )
    end
  end
end
