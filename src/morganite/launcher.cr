require "atomic"
require "./processor"
require "./retry_poller"
require "./scheduled_poller"
require "./cron_scheduler"
require "./web"
require "./hooks"

module Morganite
  class Launcher
    def initialize(
      @queues : Array(String) = [Morganite.config.queue],
      @concurrency : Int32 = Morganite.config.concurrency,
    )
      @jobs = Channel(String).new(@concurrency * 2)
      @shutdown = Channel(Nil).new
      @done = Channel(Nil).new(@concurrency)
      @retry_poller = RetryPoller.new
      @scheduled_poller = ScheduledPoller.new
      @cron_scheduler = CronScheduler.new
      @before_first_fetch = Atomic(Int32).new(0)
    end

    def run
      Hooks.run_startup

      spawn { fetch_loop }

      @concurrency.times do
        spawn { worker_loop }
      end

      spawn { @retry_poller.run }
      spawn { @scheduled_poller.run }
      spawn { @cron_scheduler.run }
      spawn { Morganite::Web.start }

      @shutdown.receive
      @jobs.close
      @concurrency.times { @done.receive }
      Hooks.run_after_last_fetch
      @retry_poller.stop
      @scheduled_poller.stop
      @cron_scheduler.stop
      Morganite::Web.stop
      Hooks.run_shutdown
    end

    def stop
      @shutdown.send(nil) rescue nil
    end

    private def fetch_loop
      Morganite.pool.with do |redis|
        loop do
          trigger_before_first_fetch
          queue_keys = @queues.map { |queue| "morganite:queue:#{queue}" }
          result = redis.brpop(queue_keys, timeout: 1)
          break unless result

          @jobs.send(result[1].as(String))
        end
      end
    ensure
      @jobs.close
    end

    private def worker_loop
      Morganite.pool.with do |redis|
        processor = Processor.new(redis)

        while job = @jobs.receive?
          processor.process(job)
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
