require "../redis_connection"
require "../job"
require "../logger"
require "./lease"

module Morganite
  module Jqcp
    # JQCP Section 8.9 (Lease-Timeout-Expired Event, draft-difluri-jqcp-02
    # numbering; was 8.8 in -01). Unlike `OrphanReaper`
    # (process-level: an entire processing list is reaped once its owner's
    # heartbeat disappears), this is a *per-job* timeout, opt-in via
    # `timeout_seconds` — it fires even if the owning worker is still alive
    # and beating normally (e.g. one job hung while the process itself is
    # fine). Requeues without incrementing retry_count (Section 8.9: "making
    # it eligible for FETCH... without incrementing retry.count" — this is
    # lease recovery, not a failure).
    class LeaseReaper
      def initialize(@poll_interval : Time::Span = 5.seconds)
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
              Logger.error("jqcp lease reaper poll failed, will retry next cycle: #{ex.class}: #{ex.message}")
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
          result = redis.zrangebyscore(Lease::KEY, "-inf", now.to_s)
          return unless result.is_a?(Array)

          expired_jobs(redis, result).each { |job| reap_one(redis, job) }
        end
      end

      private def expired_jobs(redis : Redis::Client, raw_entries) : Array(Job)
        jobs = [] of Job
        raw_entries.each do |item|
          next unless item.is_a?(String)
          begin
            jobs << Job.from_json(item)
          rescue ex : JSON::ParseException
            Logger.error("jqcp lease reaper: dropping unparseable lease entry: #{ex.message}")
            redis.zrem(Lease::KEY, item)
          end
        end
        jobs
      end

      # A lease entry whose Job is no longer in any processing list means
      # Ack/Fail already handled it (or requeued it via retry) before the
      # timeout fired — just clear the stale entry, nothing to reap.
      private def reap_one(redis : Redis::Client, expired_job : Job)
        found = Lease.find_anywhere(redis, expired_job.jid)
        unless found
          Lease.untrack(redis, expired_job)
          return
        end

        owner, job = found
        Lease.release(redis, owner, job)
        redis.lpush(job.queue_key, job.to_json)
        Logger.warn("jqcp lease reaper: requeued job #{job.jid} (was leased to #{owner}) after lease timeout")
      end
    end
  end
end
