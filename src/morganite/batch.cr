require "uuid"
require "./job"
require "./client"
require "./redis_connection"
require "./logger"

module Morganite
  class Batch
    KEY_PREFIX = "morganite:batch:"

    getter bid : String
    getter description : String
    getter success_callback : String?
    getter complete_callback : String?

    def initialize(
      @description : String = "",
      @success_callback : String? = nil,
      @complete_callback : String? = nil,
      @bid : String = UUID.random.to_s,
    )
      create_batch_record
    end

    def add(worker_name : String, args : Array(JSON::Any), queue : String = Morganite.config.queue) : Job
      # `pending` must be bumped *before* the job is enqueued, not after: a
      # worker can pick up and finish the job the instant it's visible on the
      # queue. If the increment happened afterwards, a fast-completing job
      # could decrement `pending` before its own increment ever ran, letting
      # `pending` legitimately cross zero more than once while a batch is
      # still being built — firing the completion callbacks early and more
      # than once.
      Morganite.pool.with do |redis|
        redis.hincrby(key, "total", 1)
        redis.hincrby(key, "pending", 1)
      end

      Client.enqueue(worker_name, args, queue, bid: @bid).as(Job)
    end

    # Must be called once all `add` calls for this batch are done (`open`
    # calls it for you). `pending` is seeded with one extra "construction"
    # token (see `create_batch_record`) specifically so it can't hit zero
    # while jobs are still being added faster than they're enqueued here —
    # `finish` releases that token, which is what actually allows the batch
    # to complete once every added job has too.
    def finish
      Batch.release_pending_token(@bid)
    end

    def self.open(description : String = "", success : String? = nil, complete : String? = nil, &)
      batch = new(description: description, success_callback: success, complete_callback: complete)
      yield batch
      batch.finish
      batch
    end

    def self.on_success(bid : String)
      update_counters(bid, success: true)
    end

    def self.on_failure(bid : String)
      update_counters(bid, success: false)
    end

    private def self.update_counters(bid : String, success : Bool)
      key = "#{KEY_PREFIX}#{bid}"
      state = decrement_pending(key) do |redis|
        redis.hincrby(key, success ? "success" : "fail", 1)
      end

      fire_callbacks(bid, state) if state
    end

    def self.release_pending_token(bid : String)
      key = "#{KEY_PREFIX}#{bid}"
      state = decrement_pending(key) { }
      fire_callbacks(bid, state) if state
    end

    private record CompletionState, fail_count : Int32, complete_callback : String?, success_callback : String?

    # Decrements `pending` and, if that decrement brought it to exactly zero,
    # reads back everything needed to fire callbacks — all inside one
    # borrowed connection, atomically with respect to other concurrent
    # decrements (see the comment on `fire_callbacks` for why the callback
    # enqueue itself must happen *outside* this block).
    private def self.decrement_pending(key : String, &) : CompletionState?
      state = nil

      Morganite.pool.with do |redis|
        # hincrby returns the post-decrement value atomically, so exactly one
        # concurrent caller ever observes `pending == 0` here. A separate GET
        # afterwards would race: two callers could both read 0 and fire the
        # completion callbacks twice.
        pending = redis.hincrby(key, "pending", -1)
        yield redis

        if pending.is_a?(Int) && pending == 0
          fc = redis.hget(key, "fail")
          fail_count = fc.is_a?(String) ? fc.to_i : 0
          complete_callback = redis.hget(key, "complete_callback")
          success_callback = redis.hget(key, "success_callback")
          state = CompletionState.new(fail_count, complete_callback.as?(String), success_callback.as?(String))
        end
      end

      state
    end

    # Enqueuing the callback jobs must happen *outside* the pool-borrowed
    # block above: Client.enqueue needs its own connection from the same
    # pool, and a fiber that's already holding its one long-lived connection
    # (e.g. a worker fiber) plus a second borrowed one here would try to
    # check out a *third* connection while the pool is fully checked out at
    # steady state (fetch_loop + all worker_loops permanently hold
    # concurrency+1 of the concurrency+2 slots) — a self-deadlock, since
    # nothing else is ever going to return a connection to unblock it.
    private def self.fire_callbacks(bid : String, state : CompletionState)
      Logger.info("batch #{bid} complete (#{state.fail_count} failed)")

      if (cb = state.complete_callback) && !cb.empty?
        Client.enqueue(cb, [JSON.parse(%Q{"#{bid}"})])
      end

      if state.fail_count == 0 && (sb = state.success_callback) && !sb.empty?
        Client.enqueue(sb, [JSON.parse(%Q{"#{bid}"})])
      end
    end

    private def key
      "#{KEY_PREFIX}#{@bid}"
    end

    private def create_batch_record
      Morganite.pool.with do |redis|
        redis.hmset(key, {
          "description" => @description,
          "total"       => "0",
          # Seeded at 1, not 0: this extra "construction" token represents
          # the batch itself and is only released by `finish`, so `pending`
          # can't reach zero purely because jobs happened to finish faster
          # than `add` could enqueue the rest of them.
          "pending"           => "1",
          "success"           => "0",
          "fail"              => "0",
          "success_callback"  => @success_callback || "",
          "complete_callback" => @complete_callback || "",
        })
      end
    end
  end
end
