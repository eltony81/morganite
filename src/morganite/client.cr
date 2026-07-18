require "./job"
require "./redis_connection"
require "./client_middleware"
require "./unique_jobs"

module Morganite
  module Client
    UNIQUE_ENQUEUE_SCRIPT = <<-LUA
      local lock_key = KEYS[1]
      local lock_value = ARGV[1]
      local ttl = tonumber(ARGV[2])
      local dest_key = ARGV[3]
      local job_json = ARGV[4]
      local dest_type = ARGV[5]

      local acquired
      if ttl > 0 then
        acquired = redis.call('set', lock_key, lock_value, 'nx', 'ex', ttl)
      else
        acquired = redis.call('set', lock_key, lock_value, 'nx')
      end

      if not acquired then
        return 0
      end

      if dest_type == 'scheduled' then
        redis.call('zadd', dest_key, ARGV[6], job_json)
      else
        redis.call('lpush', dest_key, job_json)
      end

      return 1
    LUA

    def self.enqueue(
      worker_name : String,
      args : Array(JSON::Any),
      queue : String = Morganite.config.queue,
      retry : Bool | Int32 = true,
      backtrace : Bool | Int32 = true,
      dead : Bool = true,
      unique : String? = nil,
      unique_for : Int32 = 300,
      bid : String? = nil,
      wid : String? = nil,
      step_index : Int32 = 0,
    ) : Job?
      job = build_job(worker_name, args, queue, retry, backtrace, dead, unique, unique_for, bid, wid, step_index)

      if job.unique && job.unique != "while_executing"
        acquired = false
        Morganite.pool.with do |redis|
          ClientMiddleware.invoke(job, -> {
            acquired = unique_enqueue(redis, job, job.queue_key, "queue")
            nil
          })
        end
        return nil unless acquired
      else
        ClientMiddleware.invoke(job, -> {
          Morganite.pool.with do |redis|
            redis.pipeline do |pipe|
              pipe.lpush(job.queue_key, job.to_json)
            end
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
      retry : Bool | Int32 = true,
      backtrace : Bool | Int32 = true,
      dead : Bool = true,
      unique : String? = nil,
      unique_for : Int32 = 300,
      bid : String? = nil,
      wid : String? = nil,
      step_index : Int32 = 0,
    ) : Job?
      job = build_job(worker_name, args, queue, retry, backtrace, dead, unique, unique_for, bid, wid, step_index)

      if job.unique && job.unique != "while_executing"
        acquired = false
        Morganite.pool.with do |redis|
          ClientMiddleware.invoke(job, -> {
            acquired = unique_enqueue(redis, job, "morganite:scheduled", "scheduled", score: time.to_unix.to_s)
            nil
          })
        end
        return nil unless acquired
      else
        ClientMiddleware.invoke(job, -> {
          Morganite.pool.with do |redis|
            redis.pipeline do |pipe|
              pipe.zadd("morganite:scheduled", time.to_unix, job.to_json)
            end
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

    private def self.unique_enqueue(
      redis : Redis::Client,
      job : Job,
      dest_key : String,
      dest_type : String,
      score : String? = nil,
    ) : Bool
      ttl = job.unique == "until_expired" ? job.unique_for : 0
      args = [
        job.jid,
        ttl.to_s,
        dest_key,
        job.to_json,
        dest_type,
      ]
      args << score if score

      result = redis.eval(UNIQUE_ENQUEUE_SCRIPT, keys: [UniqueJobs.lock_key(job)], args: args)
      result == 1
    end

    def self.build_job(
      worker_name,
      args,
      queue,
      retry = true,
      backtrace = true,
      dead = true,
      unique = nil,
      unique_for = 300,
      bid = nil,
      wid = nil,
      step_index = 0,
    )
      Job.new(
        class: worker_name,
        args: args,
        queue: queue,
        retry: retry,
        backtrace: backtrace,
        dead: dead,
        unique: unique,
        unique_for: unique_for,
        bid: bid,
        wid: wid,
        step_index: step_index,
        enqueued_at: Time.utc.to_unix_f
      )
    end
  end
end
