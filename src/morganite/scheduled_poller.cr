require "./redis_connection"
require "./job"
require "./poller_script"
require "./logger"

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
          begin
            poll
          rescue ex : Exception
            # Without this, a single Redis hiccup would kill this fiber
            # forever: no more scheduled jobs would ever become due.
            Logger.error("scheduled poller failed, will retry next cycle: #{ex.class}: #{ex.message}")
          end
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
        return if jobs.empty?

        moved = PollerScript.move_mature_jobs(redis, SCHEDULED_KEY, jobs)
        Logger.debug("scheduled poller moved #{moved} job(s) to their queue") if moved > 0
      end
    end
  end
end
