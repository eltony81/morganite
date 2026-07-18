require "./cron"
require "./client"
require "./redis_connection"

module Morganite
  class CronScheduler
    LAST_RUN_KEY = "morganite:cron:last_run"

    def initialize(@poll_interval : Time::Span = 30.seconds)
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
      Cron.jobs.each do |cron_job|
        location = cron_job.location
        now = Time.local(location)
        last_run = last_run_for(cron_job.key)
        from = last_run || (now - 1.minute)
        from = from.in(location)
        next_time = cron_job.cron.next(from)

        if next_time <= now
          Client.schedule(cron_job.worker_name, next_time, cron_job.args, Morganite.config.queue)
          set_last_run(cron_job.key, next_time)
        end
      end
    end

    private def last_run_for(key : String) : Time?
      Morganite.pool.with do |redis|
        value = redis.hget(LAST_RUN_KEY, key)
        next unless value.is_a?(String)
        Time.unix(value.to_i)
      end
    end

    private def set_last_run(key : String, time : Time)
      Morganite.pool.with do |redis|
        redis.hset(LAST_RUN_KEY, key, time.to_unix.to_s)
      end
    end
  end

  module Cron
    record Job, worker_name : String, expression : String, timezone : String?, args : Array(JSON::Any), cron : CronExpression do
      def key
        "#{worker_name}:#{expression}"
      end

      def location : Time::Location
        if tz = timezone
          return Time::Location.load(tz)
        end
        Time::Location::UTC
      end
    end

    @@jobs = [] of Job

    def self.register(worker_name : String, expression : String, timezone : String? = nil, args = [] of JSON::Any)
      @@jobs << Job.new(worker_name, expression, timezone, args, CronExpression.new(expression))
    end

    def self.jobs
      @@jobs
    end

    def self.clear
      @@jobs.clear
    end
  end
end
