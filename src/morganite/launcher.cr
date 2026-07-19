require "atomic"
require "./processor"
require "./retry_poller"
require "./scheduled_poller"
require "./cron_scheduler"
require "./orphan_reaper"
require "./jqcp/queue_control"
require "./jqcp/lease_reaper"
require "./web"
require "./hooks"
require "./logger"

module Morganite
  class Launcher
    HEARTBEAT_PREFIX           = "morganite:processes:"
    HEARTBEAT_TTL              = 45.seconds
    HEARTBEAT_REFRESH_INTERVAL = 10.seconds

    def initialize(
      @queues : Array(String) = [Morganite.config.queue],
      @concurrency : Int32 = Morganite.config.concurrency,
      @start_web : Bool = true,
    )
      @jobs = Channel(String).new(@concurrency * 2)
      @shutdown = Channel(Nil).new
      @done = Channel(Nil).new(@concurrency)
      @retry_poller = RetryPoller.new
      @scheduled_poller = ScheduledPoller.new
      @cron_scheduler = CronScheduler.new
      @orphan_reaper = OrphanReaper.new(poll_interval: Morganite.config.orphan_reaper_poll_interval_seconds.seconds)
      @lease_reaper = Jqcp::LeaseReaper.new
      @before_first_fetch = Atomic(Int32).new(0)
      @processing_key = "morganite:processing:#{System.hostname}:#{Process.pid}"
      @heartbeat_key = "#{HEARTBEAT_PREFIX}#{System.hostname}:#{Process.pid}"
      @last_heartbeat = Atomic(Int64).new(0_i64)
    end

    def run
      Hooks.run_startup
      Logger.info("launcher starting: queues=#{@queues.join(",")} concurrency=#{@concurrency}")

      spawn { fetch_loop }

      @concurrency.times do
        spawn { worker_loop }
      end

      spawn { @retry_poller.run }
      spawn { @scheduled_poller.run }
      spawn { @cron_scheduler.run }
      spawn { @orphan_reaper.run }
      spawn { @lease_reaper.run }
      spawn { Morganite::Web.start } if @start_web

      wait_for_shutdown_request
      Logger.info("shutdown requested: draining in-flight jobs")
      @jobs.close
      @concurrency.times { @done.receive }
      Logger.info("shutdown: workers drained")
      Hooks.run_after_last_fetch
      @retry_poller.stop
      @scheduled_poller.stop
      @cron_scheduler.stop
      @orphan_reaper.stop
      @lease_reaper.stop
      Logger.info("shutdown: pollers stopped")
      Morganite::Web.stop if @start_web
      Hooks.run_shutdown
      Logger.info("shutdown complete")
    end

    # Closing (not sending on) @shutdown is deliberate: both `fetch_loop` and
    # `wait_for_shutdown_request` need to observe this independently, and a
    # channel only ever delivers a given `send` to a single `receive`. Using
    # `close` broadcasts to every current and future waiter instead.
    def stop
      @shutdown.close
    rescue Channel::ClosedError
    end

    private def wait_for_shutdown_request
      @shutdown.receive
    rescue Channel::ClosedError
    end

    private def fetch_loop
      Morganite.pool.with do |redis|
        loop do
          break if @shutdown.closed?

          maybe_send_heartbeat(redis)
          trigger_before_first_fetch
          queue_keys = Jqcp::QueueControl.select_queue_keys(redis, @queues)
          if queue_keys.empty?
            # Every queue is paused (Section 9.3): BRPOPLPUSH's own timeout
            # normally paces this loop, but with nothing to block on here
            # this would otherwise spin at full CPU until something resumes.
            sleep 1.second
            next
          end

          if job_json = fetch_one(redis, queue_keys)
            begin
              @jobs.send(job_json)
            rescue Channel::ClosedError
              # Shutdown raced us between the fetch above and this send: the
              # job is already sitting in @processing_key. Don't drop it on
              # the floor, put it back on its queue before this fiber exits.
              requeue_unsent_job(redis, job_json)
              break
            end
          end
        end
      end
    ensure
      @jobs.close
    end

    private def fetch_one(redis : Redis::Client, queue_keys : Array(String)) : String?
      queue_keys.each do |queue_key|
        result = redis.brpoplpush(queue_key, @processing_key, timeout: 1)
        return result.as(String) if result.is_a?(String)
      end
      nil
    end

    private def requeue_unsent_job(redis : Redis::Client, job_json : String)
      redis.lrem(@processing_key, 0, job_json)
      queue_key = Job.from_json(job_json).queue_key
      redis.lpush(queue_key, job_json)
    rescue ex : Exception
      Logger.error("failed to requeue job during shutdown race, it remains in #{@processing_key}: #{ex.class}: #{ex.message}")
    end

    # Refreshed well before HEARTBEAT_TTL expires, so OrphanReaper never
    # mistakes a live-but-briefly-idle process for a dead one.
    private def maybe_send_heartbeat(redis : Redis::Client)
      now = Time.utc.to_unix
      last = @last_heartbeat.get
      return if now - last < HEARTBEAT_REFRESH_INTERVAL.total_seconds

      redis.set(@heartbeat_key, "1", ex: HEARTBEAT_TTL.total_seconds.to_i)
      @last_heartbeat.set(now)
    rescue ex : Exception
      Logger.error("failed to write heartbeat: #{ex.class}: #{ex.message}")
    end

    private def worker_loop
      Morganite.pool.with do |redis|
        processor = Processor.new(redis)

        while job = @jobs.receive?
          begin
            processor.process(job)
          rescue ex : Exception
            # Belt-and-suspenders: Processor#process already rescues job
            # execution failures internally, but if something outside that
            # (a bug, a Redis error in the unique-lock/rate-limit path, etc.)
            # still raises, this fiber must survive it. Losing a worker fiber
            # here silently shrinks the effective concurrency for the rest of
            # the process's life.
            Logger.error("worker fiber caught unexpected exception processing a job; continuing: #{ex.class}: #{ex.message}")
          ensure
            redis.lrem(@processing_key, 0, job)
          end
        end
      end
    ensure
      @done.send(nil)
    end

    private def trigger_before_first_fetch
      _old, success = @before_first_fetch.compare_and_set(0, 1)
      Hooks.run_before_first_fetch if success
    end
  end
end
