require "digest/sha256"
require "./job"
require "./redis_connection"

module Morganite
  module UniqueJobs
    PREFIX = "morganite:unique:"

    def self.unique_key(job : Job) : String
      "#{job.class}|#{job.queue}|#{job.args.to_json}"
    end

    def self.unique_key(class_name : String, queue : String, args : Array(JSON::Any)) : String
      "#{class_name}|#{queue}|#{args.to_json}"
    end

    def self.lock_key(job : Job) : String
      "#{PREFIX}#{Digest::SHA256.hexdigest(unique_key(job))}"
    end

    def self.lock_key(unique_key : String) : String
      "#{PREFIX}#{Digest::SHA256.hexdigest(unique_key)}"
    end

    # Acquires a unique lock for the given job using `SET key value NX EX <ttl>`.
    # When `ttl` is `nil` the lock is created without expiration.
    def self.lock(job : Job, ttl : Int32? = nil, redis : Redis::Client? = nil) : Bool
      key = lock_key(job)
      value = job.jid
      client = redis || RedisConnection.new_client

      result = if ttl
                 client.set(key, value, nx: true, ex: ttl)
               else
                 client.set(key, value, nx: true)
               end

      result == "OK"
    end

    # Releases a unique lock by job or raw unique key (class|queue|args).
    def self.unlock(job_or_key : Job | String, redis : Redis::Client? = nil)
      key = job_or_key.is_a?(Job) ? lock_key(job_or_key) : lock_key(job_or_key)
      client = redis || RedisConnection.new_client
      client.del(key)
      nil
    end
  end
end
