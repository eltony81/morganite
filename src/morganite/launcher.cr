require "./processor"
require "./retry_poller"
require "./scheduled_poller"
require "./cron_scheduler"

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
    end

    def run
      spawn { fetch_loop }

      @concurrency.times do
        spawn { worker_loop }
      end

      spawn { @retry_poller.run }
      spawn { @scheduled_poller.run }
      spawn { @cron_scheduler.run }

      @shutdown.receive
      @jobs.close
      @concurrency.times { @done.receive }
      @retry_poller.stop
      @scheduled_poller.stop
      @cron_scheduler.stop
    end

    def stop
      @shutdown.send(nil) rescue nil
    end

    private def fetch_loop
      Morganite.pool.with do |redis|
        loop do
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
  end
end
