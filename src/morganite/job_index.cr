require "./job"
require "./redis_connection"

module Morganite
  # Secondary index (jid -> {location, job JSON}) so looking up a specific
  # job by jid in the retry/dead/scheduled sorted sets doesn't require an
  # O(N) ZRANGE + linear scan (previously the only option, and the cost of
  # every retry/delete/dashboard-detail lookup against a set that can hold
  # up to `dead_max_jobs`, or an unbounded number of retry/scheduled jobs).
  #
  # The index is a *hint*, not a source of truth: it can go stale (a poller
  # move, a dead-set trim, or an older job created before this index
  # existed) without ever causing an incorrect result. `find_any`/`find_in`
  # verify the entry is still actually present via `ZSCORE` before trusting
  # it; callers fall back to their own O(N) scan when the index misses.
  # Normal queue lists are intentionally not indexed here — they're meant
  # to drain quickly, and indexing every enqueue/dequeue would tax the hot
  # path to speed up a comparatively rare dashboard lookup.
  module JobIndex
    KEY = "morganite:job_index"

    record Entry, location : String, job : String do
      include JSON::Serializable
    end

    def self.set(redis : Redis::Client, location : String, job : Job)
      redis.hset(KEY, job.jid, Entry.new(location, job.to_json).to_json)
    end

    def self.delete(redis : Redis::Client, jid : String)
      redis.hdel(KEY, jid)
    end

    def self.delete_all(redis : Redis::Client, jobs : Array(Job))
      return if jobs.empty?
      redis.hdel(KEY, jobs.map(&.jid))
    end

    # Verified lookup regardless of which sorted set the job is indexed
    # under. Returns nil on a miss or a stale entry — never a false positive.
    def self.find_any(redis : Redis::Client, jid : String) : Tuple(Job, String)?
      entry_json = redis.hget(KEY, jid)
      return nil unless entry_json.is_a?(String)

      entry = Entry.from_json(entry_json)
      return nil unless redis.zscore(entry.location, entry.job)

      {Job.from_json(entry.job), entry.location}
    rescue ex : JSON::ParseException
      nil
    end

    # Same as `find_any`, but only trusted if indexed under `location` specifically.
    def self.find_in(redis : Redis::Client, location : String, jid : String) : Job?
      found = find_any(redis, jid)
      return nil unless found

      job, found_location = found
      found_location == location ? job : nil
    end
  end
end
