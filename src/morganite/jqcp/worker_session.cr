require "json"
require "../redis_connection"
require "../logger"

module Morganite
  module Jqcp
    # JQCP Section 7.8 (draft-difluri-jqcp-02 numbering; was 7.7 in -01):
    # Worker Session Lifecycle, keyed by wid, independent
    # of any single gRPC Channel (Not Identified -> Identified -> Quiet ->
    # Terminating -> Closed). Since this Broker doesn't implement streaming
    # Fetch (see docs/jqcp_conformance.md), there is no server-observable
    # event for a Worker entering Quiet on its own (Section 7.7: it would
    # normally do so by ending its Fetch stream) — a Worker in this
    # transport simply stops calling Fetch, which the Broker can't
    # distinguish from "temporarily idle." Session state therefore only
    # ever reaches "identified" here; Quiet/Terminating are represented in
    # the enum for vocabulary completeness but are not actively driven
    # server-side in this implementation (documented gap).
    module WorkerSession
      SESSION_PREFIX = "morganite:jqcp:session:"

      # Same key prefix Launcher uses for its own per-process heartbeat
      # (`Launcher::HEARTBEAT_PREFIX`, src/morganite/launcher.cr) — a JQCP
      # worker's wid is written under the identical `morganite:processes:*`
      # namespace on purpose, so `OrphanReaper` (which scans that namespace
      # generically) recovers a dead JQCP worker's in-flight jobs with no
      # JQCP-specific reaping logic needed.
      HEARTBEAT_PREFIX      = "morganite:processes:"
      HEARTBEAT_TTL_SECONDS = 45

      enum State
        Identified
        Quiet
        Terminating
      end

      record Session, state : String, queues : Array(String), concurrency : Int32, last_beat : Float64 do
        include JSON::Serializable
      end

      def self.session_key(wid : String) : String
        "#{SESSION_PREFIX}#{wid}"
      end

      def self.heartbeat_key(wid : String) : String
        "#{HEARTBEAT_PREFIX}#{wid}"
      end

      # Section 7.1: moves wid out of Not Identified into Identified,
      # creating its session record and starting its heartbeat so
      # OrphanReaper coverage begins immediately.
      def self.hello(redis : Redis::Client, wid : String, queues : Array(String), concurrency : Int32) : Session
        session = Session.new(State::Identified.to_s, queues, concurrency, Time.utc.to_unix_f)
        persist(redis, wid, session)
        Logger.info("jqcp: worker #{wid} identified (queues=#{queues.join(",")} concurrency=#{concurrency})")
        session
      end

      # Section 7.7 (draft-difluri-jqcp-02; was 7.6 in -01): refreshes both
      # the session record and its heartbeat TTL. Returns nil if wid never
      # said Hello or its session has expired (Not Identified / Closed) —
      # callers must reject per Section 7.1.
      def self.beat(redis : Redis::Client, wid : String) : Session?
        session = find(redis, wid)
        return nil unless session

        refreshed = Session.new(session.state, session.queues, session.concurrency, Time.utc.to_unix_f)
        persist(redis, wid, refreshed)
        refreshed
      end

      def self.find(redis : Redis::Client, wid : String) : Session?
        raw = redis.get(session_key(wid))
        return nil unless raw.is_a?(String)

        Session.from_json(raw)
      rescue ex : JSON::ParseException
        nil
      end

      def self.identified?(redis : Redis::Client, wid : String) : Bool
        !find(redis, wid).nil?
      end

      # Section 9.9 (ListWorkers): every currently-known (non-Closed) session.
      def self.all(redis : Redis::Client) : Array({String, Session})
        RedisConnection.scan_keys(redis, "#{SESSION_PREFIX}*").compact_map do |key|
          wid = key.sub(SESSION_PREFIX, "")
          session = find(redis, wid)
          session ? {wid, session} : nil
        end
      end

      private def self.persist(redis : Redis::Client, wid : String, session : Session)
        redis.set(session_key(wid), session.to_json, ex: HEARTBEAT_TTL_SECONDS)
        redis.set(heartbeat_key(wid), "1", ex: HEARTBEAT_TTL_SECONDS)
      end
    end
  end
end
