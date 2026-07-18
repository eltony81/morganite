require "./redis_connection"
require "./job"
require "./poller_script"
require "./logger"

module Morganite
  # Requeues jobs left behind in a `morganite:processing:<host>:<pid>` list by
  # a process that died without a graceful shutdown (OOM, SIGKILL, crash).
  # Nothing else in the system ever revisits those jobs otherwise: reliable
  # fetch (BRPOPLPUSH) only protects against losing a job *in transit*, not
  # against losing the process that was about to run it.
  #
  # A process is considered dead once its heartbeat key
  # (`morganite:processes:<host>:<pid>`, written by Launcher#fetch_loop) has
  # expired. The heartbeat TTL/refresh margins are generous on purpose so a
  # live-but-briefly-slow process is never mistaken for a dead one.
  class OrphanReaper
    PROCESSING_PREFIX = "morganite:processing:"
    HEARTBEAT_PREFIX  = "morganite:processes:"

    def initialize(@poll_interval : Time::Span = 30.seconds)
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
            Logger.error("orphan reaper poll failed, will retry next cycle: #{ex.class}: #{ex.message}")
          end
        end
      end
    end

    def stop
      @shutdown.send(nil) rescue nil
    end

    private def poll
      Morganite.pool.with do |redis|
        RedisConnection.scan_keys(redis, "#{PROCESSING_PREFIX}*").each do |processing_key|
          owner = processing_key.sub(PROCESSING_PREFIX, "")
          next if redis.exists("#{HEARTBEAT_PREFIX}#{owner}") == 1

          reap(redis, processing_key, owner)
        end
      end
    end

    private def reap(redis : Redis::Client, processing_key : String, owner : String)
      result = redis.lrange(processing_key, 0, -1)
      return unless result.is_a?(Array)

      jobs = [] of Job
      result.each do |item|
        next unless item.is_a?(String)
        begin
          jobs << Job.from_json(item)
        rescue ex : JSON::ParseException
          Logger.error("orphan reaper: dropping unparseable job in #{processing_key}: #{ex.message}")
          redis.lrem(processing_key, 1, item)
        end
      end
      return if jobs.empty?

      moved = PollerScript.requeue_orphaned_jobs(redis, processing_key, jobs)
      redis.del(processing_key)
      Logger.warn("orphan reaper: requeued #{moved} job(s) from dead process #{owner}") if moved > 0
    end
  end
end
