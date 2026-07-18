module Morganite
  module PollerScript
    MOVE_MATURE_JOBS = <<-LUA
      local key = KEYS[1]
      local argc = #ARGV
      local moved = 0

      for i = 1, argc, 2 do
        local job_json = ARGV[i]
        local queue_key = ARGV[i + 1]
        if redis.call('zrem', key, job_json) == 1 then
          redis.call('lpush', queue_key, job_json)
          moved = moved + 1
        end
      end

      return moved
    LUA

    def self.move_mature_jobs(redis : Redis::Client, key : String, jobs : Array(Job)) : Int64
      args = [] of String
      jobs.each do |job|
        args << job.to_json
        args << job.queue_key
      end

      result = redis.eval(MOVE_MATURE_JOBS, keys: [key], args: args)
      result.is_a?(Int) ? result.to_i64 : 0_i64
    end

    # Same idea as MOVE_MATURE_JOBS but the source is a LIST (a processing
    # key), removed with LREM instead of ZREM.
    REQUEUE_ORPHANED_JOBS = <<-LUA
      local key = KEYS[1]
      local argc = #ARGV
      local moved = 0

      for i = 1, argc, 2 do
        local job_json = ARGV[i]
        local queue_key = ARGV[i + 1]
        if redis.call('lrem', key, 1, job_json) == 1 then
          redis.call('lpush', queue_key, job_json)
          moved = moved + 1
        end
      end

      return moved
    LUA

    def self.requeue_orphaned_jobs(redis : Redis::Client, processing_key : String, jobs : Array(Job)) : Int64
      args = [] of String
      jobs.each do |job|
        args << job.to_json
        args << job.queue_key
      end

      result = redis.eval(REQUEUE_ORPHANED_JOBS, keys: [processing_key], args: args)
      result.is_a?(Int) ? result.to_i64 : 0_i64
    end
  end
end
