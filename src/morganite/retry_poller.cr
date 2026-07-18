require "./redis_connection"
require "./job"
require "./failures"
require "./poller_script"
require "./logger"
require "./job_index"

module Morganite
  class RetryPoller
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
            # forever: no more scheduled retries would ever get re-queued.
            Logger.error("retry poller failed, will retry next cycle: #{ex.class}: #{ex.message}")
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
        result = redis.zrangebyscore(Failures::RETRY_KEY, "-inf", now.to_s)
        return unless result.is_a?(Array)

        jobs = [] of Job
        result.each do |job_json|
          next unless job_json.is_a?(String)
          jobs << Job.from_json(job_json)
        end
        return if jobs.empty?

        moved = PollerScript.move_mature_jobs(redis, Failures::RETRY_KEY, jobs)
        JobIndex.delete_all(redis, jobs)
        Logger.debug("retry poller moved #{moved} job(s) back to their queue") if moved > 0
      end
    end
  end
end
