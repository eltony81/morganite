require "./job"
require "./registry"
require "./failures"
require "./server_middleware"
require "./metrics"
require "./logger"

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

      elapsed = Time.measure do
        ServerMiddleware.invoke(job, worker, job.queue, -> {
          worker.perform(job.args)
          nil
        })
      end

      Metrics.increment("jobs_processed")
      Metrics.observe("#{job.class}_duration", elapsed.total_seconds)
      log.info("finished job #{job.class} in #{elapsed.total_milliseconds.round(2)}ms")
    rescue ex : Exception
      Metrics.increment("jobs_failed")
      log_context = Logger.context(jid: job.try(&.jid))
      log_context.error("job failed: #{ex.class}: #{ex.message}")

      if parsed_job = job
        Failures.handle(parsed_job, ex, @redis)
      else
        STDERR.puts "Failed to parse job: #{ex.message}"
      end
    end
  end
end
