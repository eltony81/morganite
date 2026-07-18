require "digest/sha256"
require "./job"
require "./redis_connection"
require "./logger"

module Morganite
  module UniqueJobs
    PREFIX = "morganite:unique:"

    # Deletes the lock only if it still holds the value we set (compare-and-delete).
    # A plain DEL would let a job release a lock it no longer owns after its TTL
    # expired and a different job instance acquired it in the meantime.
    UNLOCK_SCRIPT = <<-LUA
      if redis.call('get', KEYS[1]) == ARGV[1] then
        return redis.call('del', KEYS[1])
      else
        return 0
      end
    LUA

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

      acquired = result == "OK"
      Logger.debug("unique lock #{acquired ? "acquired" : "contended"} for #{job.class} (#{job.jid})")
      acquired
    end

    # Releases a job's unique lock, but only if the lock still belongs to this
    # job's jid. Prevents a slow job whose lock TTL already expired from
    # deleting the lock a different job instance has since acquired.
    def self.unlock(job : Job, redis : Redis::Client? = nil)
      client = redis || RedisConnection.new_client
      result = client.eval(UNLOCK_SCRIPT, keys: [lock_key(job)], args: [job.jid])
      if result == 1
        Logger.debug("unique lock released for #{job.class} (#{job.jid})")
      else
        Logger.debug("unique lock for #{job.class} (#{job.jid}) already owned by a different instance; not released")
      end
      nil
    end

    # Releases a lock by raw unique key (class|queue|args) unconditionally.
    # There is no jid to compare against here, so callers must ensure no
    # other job instance currently owns this lock.
    def self.unlock(unique_key : String, redis : Redis::Client? = nil)
      client = redis || RedisConnection.new_client
      client.del(lock_key(unique_key))
      nil
    end
  end
end
