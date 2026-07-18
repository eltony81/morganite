require "./job"
require "./registry"
require "./retry"
require "./failures"
require "./server_middleware"
require "./metrics"
require "./logger"
require "./unique_jobs"
require "./batch"
require "./rate_limiter"
require "./workflow"

module Morganite
  class Processor
    def initialize(@redis : Redis::Client? = nil)
    end

    # Threshold above which a completed job is logged as slow, purely for
    # observability (does not affect retry/backoff behavior).
    SLOW_JOB_THRESHOLD = 5.seconds

    def process(job_json : String)
      # A payload that doesn't even parse has no jid/class to hand to
      # Failures.handle, so there's nothing to retry: log and drop it rather
      # than letting the exception escape and kill this worker fiber.
      job = begin
        Job.from_json(job_json)
      rescue ex : JSON::ParseException
        Logger.error("dropping unparseable job payload: #{ex.message}")
        Metrics.increment("jobs_unparseable")
        return
      end

      log = Logger.context(jid: job.jid)
      log.info("start job #{job.class}")

      execution_lock = false

      begin
        # Fetching the worker factory lives inside the rescue-guarded block:
        # an unknown worker class is a per-job failure like any other and
        # should go through the normal retry/dead-letter path instead of
        # raising past this method and killing the calling fiber.
        factory = WorkerRegistry.fetch(job.class)
        worker = factory.call

        if job.unique == "while_executing"
          execution_lock = UniqueJobs.lock(job, ttl: job.unique_for, redis: @redis)
          unless execution_lock
            log.warn("could not acquire unique lock for #{job.class}; skipping")
            return
          end
        end

        limit = worker.class.rate_limit_limit
        window = worker.class.rate_limit_window
        if limit > 0 && !RateLimiter.allow?(job.class, limit, window)
          log.warn("rate limit exceeded for #{job.class}; rescheduling")
          RateLimiter.reschedule(job_json, job.queue_key)
          return
        end

        execute_job(job, worker)
        after_success(job)
      rescue ex : Exception
        handle_failure(job, ex)
      ensure
        UniqueJobs.unlock(job, redis: @redis) if execution_lock
      end
    end

    private def execute_job(job : Job, worker : Worker)
      elapsed = Time.measure do
        invoke_worker_middlewares(job, worker, job.queue, -> {
          ServerMiddleware.invoke(job, worker, job.queue, -> {
            worker.perform(job.args)
            nil
          })
        })
      end

      Metrics.increment("jobs_processed")
      Metrics.observe("#{job.class}_duration", elapsed.total_seconds)
      log = Logger.context(jid: job.jid)
      log.info("finished job #{job.class} in #{elapsed.total_milliseconds.round(2)}ms")

      if elapsed > SLOW_JOB_THRESHOLD
        log.warn("slow job: #{job.class} took #{elapsed.total_milliseconds.round(2)}ms (threshold #{SLOW_JOB_THRESHOLD.total_seconds}s)")
      end
    end

    private def after_success(job : Job)
      if job.unique == "until_executed"
        UniqueJobs.unlock(job, redis: @redis)
      end

      if bid = job.bid
        Batch.on_success(bid)
      end
      Workflow.on_step_complete(job) if job.wid
    end

    private def handle_failure(job : Job, error : Exception)
      Metrics.increment("jobs_failed")
      log_context = Logger.context(jid: job.try(&.jid))
      log_context.error("job failed: #{error.class}: #{error.message}")

      Failures.handle(job, error, @redis)

      if job.unique == "until_executed" && (error.is_a?(Discard) || !Retry.retry_job?(job))
        UniqueJobs.unlock(job, redis: @redis)
      end

      if bid = job.bid
        Batch.on_failure(bid)
      end
    end

    private def invoke_worker_middlewares(job : Job, worker : Worker, queue : String, on_done : -> Nil)
      chain = on_done
      worker.class.server_middlewares.reverse_each do |middleware|
        previous = chain.as(-> Nil)
        chain = -> { middleware.call(job, worker, queue, previous); nil }
      end
      chain.call
    end
  end
end
