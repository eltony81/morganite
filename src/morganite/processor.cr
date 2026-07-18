require "./job"
require "./registry"
require "./retry"
require "./failures"
require "./server_middleware"
require "./metrics"
require "./logger"
require "./unique_jobs"

module Morganite
  class Processor
    def initialize(@redis : Redis::Client? = nil)
    end

    def process(job_json : String)
      job = Job.from_json(job_json)
      factory = WorkerRegistry.fetch(job.class)
      worker = factory.call
      log = Logger.context(jid: job.jid)

      log.info("start job #{job.class}")

      execution_lock = false

      begin
        if job.unique == "while_executing"
          execution_lock = UniqueJobs.lock(job, ttl: job.unique_for, redis: @redis)
          unless execution_lock
            log.warn("could not acquire unique lock for #{job.class}; skipping")
            return
          end
        end

        elapsed = Time.measure do
          ServerMiddleware.invoke(job, worker, job.queue, -> {
            worker.perform(job.args)
            nil
          })
        end

        Metrics.increment("jobs_processed")
        Metrics.observe("#{job.class}_duration", elapsed.total_seconds)
        log.info("finished job #{job.class} in #{elapsed.total_milliseconds.round(2)}ms")

        if job.unique == "until_executed"
          UniqueJobs.unlock(job, redis: @redis)
        end
      rescue ex : Exception
        Metrics.increment("jobs_failed")
        log_context = Logger.context(jid: job.try(&.jid))
        log_context.error("job failed: #{ex.class}: #{ex.message}")

        if parsed_job = job
          Failures.handle(parsed_job, ex, @redis)

          if parsed_job.unique == "until_executed" && (ex.is_a?(Discard) || !Retry.retry_job?(parsed_job))
            UniqueJobs.unlock(parsed_job, redis: @redis)
          end
        else
          STDERR.puts "Failed to parse job: #{ex.message}"
        end
      ensure
        UniqueJobs.unlock(job, redis: @redis) if execution_lock
      end
    end
  end
end
