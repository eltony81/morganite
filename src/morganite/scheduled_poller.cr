require "./redis_connection"
require "./job"

module Morganite
  class ScheduledPoller
    SCHEDULED_KEY = "morganite:scheduled"

    def initialize(@poll_interval : Time::Span = 1.second)
      @shutdown = Channel(Nil).new
    end

    def run
      loop do
        select
        when @shutdown.receive
          break
        when timeout(@poll_interval)
          poll
        end
      end
    end

    def stop
      @shutdown.send(nil) rescue nil
    end

    private def poll
      Morganite.pool.with do |redis|
        now = Time.utc.to_unix
        result = redis.zrangebyscore(SCHEDULED_KEY, "-inf", now.to_s)
        return unless result.is_a?(Array)

        result.each do |job_json|
          next unless job_json.is_a?(String)

          job = Job.from_json(job_json)
          redis.zrem(SCHEDULED_KEY, job_json)
          redis.lpush(job.queue_key, job_json)
        end
      end
    end
  end
end
