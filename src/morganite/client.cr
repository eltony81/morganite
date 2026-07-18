require "./job"
require "./redis_connection"

module Morganite
  module Client
    def self.enqueue(worker_name : String, args : Array(JSON::Any), queue : String = Morganite.config.queue) : Job
      job = Job.new(
        class: worker_name,
        args: args,
        queue: queue,
        enqueued_at: Time.utc.to_unix_f
      )

      redis = RedisConnection.new_client
      redis.lpush(job.queue_key, job.to_json)
      job
    end

    def self.schedule(worker_name : String, time : Time, args : Array(JSON::Any), queue : String = Morganite.config.queue) : Job
      job = Job.new(
        class: worker_name,
        args: args,
        queue: queue,
        enqueued_at: Time.utc.to_unix_f
      )

      redis = RedisConnection.new_client
      redis.zadd("morganite:scheduled", time.to_unix, job.to_json)
      job
    end
  end
end
