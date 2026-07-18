require "uuid"
require "./job"
require "./client"
require "./redis_connection"

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
      job = Client.enqueue(worker_name, args, queue, bid: @bid).as(Job)

      Morganite.pool.with do |redis|
        redis.hincrby(key, "total", 1)
        redis.hincrby(key, "pending", 1)
      end

      job
    end

    def self.open(description : String = "", success : String? = nil, complete : String? = nil, &)
      batch = new(description: description, success_callback: success, complete_callback: complete)
      yield batch
      batch
    end

    def self.on_success(bid : String)
      update_counters(bid, success: true)
    end

    def self.on_failure(bid : String)
      update_counters(bid, success: false)
    end

    private def self.update_counters(bid : String, success : Bool)
      Morganite.pool.with do |redis|
        key = "#{KEY_PREFIX}#{bid}"
        redis.hincrby(key, "pending", -1)
        redis.hincrby(key, success ? "success" : "fail", 1)

        pending = redis.hget(key, "pending")
        pending = pending.is_a?(String) ? pending.to_i : 0

        if pending == 0
          fail_count = redis.hget(key, "fail")
          fail_count = fail_count.is_a?(String) ? fail_count.to_i : 0

          complete_callback = redis.hget(key, "complete_callback")
          success_callback = redis.hget(key, "success_callback")

          if complete_callback.is_a?(String)
            Client.enqueue(complete_callback, [JSON.parse(%Q{"#{bid}"})])
          end

          if fail_count == 0 && success_callback.is_a?(String)
            Client.enqueue(success_callback, [JSON.parse(%Q{"#{bid}"})])
          end
        end
      end
    end

    private def key
      "#{KEY_PREFIX}#{@bid}"
    end

    private def create_batch_record
      Morganite.pool.with do |redis|
        redis.hmset(key, {
          "description"       => @description,
          "total"             => "0",
          "pending"           => "0",
          "success"           => "0",
          "fail"              => "0",
          "success_callback"  => @success_callback || "",
          "complete_callback" => @complete_callback || "",
        })
      end
    end
  end
end
