require "./redis_connection"
require "./job"
require "./poller_script"

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

        jobs = [] of Job
        result.each do |job_json|
          next unless job_json.is_a?(String)
          jobs << Job.from_json(job_json)
        end

        PollerScript.move_mature_jobs(redis, SCHEDULED_KEY, jobs)
      end
    end
  end
end
