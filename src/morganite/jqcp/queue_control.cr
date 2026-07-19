require "json"
require "../redis_connection"

module Morganite
  module Jqcp
    # JQCP Section 9.3 (pause) and Section 10 (priority strategies). Wired
    # into `Launcher#fetch_one` so pause/strategy affect every fetcher
    # (native fiber workers and the JQCP Worker API's Fetch handler alike),
    # not just JQCP-originated traffic.
    module QueueControl
      STRATEGY_KEY = "morganite:jqcp:priority_strategy"

      record Strategy, mode : String, weights : Hash(String, Int32) do
        include JSON::Serializable
      end

      DEFAULT_STRATEGY = Strategy.new("strict", {} of String => Int32)

      def self.paused_key(queue : String) : String
        "morganite:queue:#{queue}:paused"
      end

      def self.pause(redis : Redis::Client, queue : String)
        redis.set(paused_key(queue), "1")
      end

      def self.resume(redis : Redis::Client, queue : String)
        redis.del(paused_key(queue))
      end

      def self.paused?(redis : Redis::Client, queue : String) : Bool
        redis.exists(paused_key(queue)) == 1
      end

      def self.strategy(redis : Redis::Client) : Strategy
        raw = redis.get(STRATEGY_KEY)
        return DEFAULT_STRATEGY unless raw.is_a?(String)

        Strategy.from_json(raw)
      rescue ex : JSON::ParseException
        DEFAULT_STRATEGY
      end

      def self.set_strategy(redis : Redis::Client, mode : String, weights : Hash(String, Int32))
        redis.set(STRATEGY_KEY, Strategy.new(mode, weights).to_json)
      end

      # Returns queue Redis keys in the order a fetcher should try them:
      # paused queues excluded entirely (Section 9.3); "strict" (the
      # default, and Launcher's original always-in-array-order behavior)
      # keeps `queue_names`' order; "weighted" draws a fetch order via
      # weighted sampling without replacement, so a higher-weighted queue is
      # more likely to be tried (and therefore win, if it has work) first on
      # any given fetch, per Section 10's "probability proportional to
      # weight" requirement. Queues absent from `weights` default to 1.
      def self.select_queue_keys(redis : Redis::Client, queue_names : Array(String)) : Array(String)
        eligible = queue_names.reject { |name| paused?(redis, name) }
        active_strategy = strategy(redis)
        ordered = active_strategy.mode == "weighted" ? weighted_order(eligible, active_strategy.weights) : eligible
        ordered.map { |name| "morganite:queue:#{name}" }
      end

      private def self.weighted_order(names : Array(String), weights : Hash(String, Int32)) : Array(String)
        remaining = names.dup
        order = [] of String

        until remaining.empty?
          total = remaining.sum { |name| weights.fetch(name, 1) }
          pick = total > 0 ? Random.rand(total) : 0
          chosen = remaining.first

          cumulative = 0
          remaining.each do |name|
            cumulative += weights.fetch(name, 1)
            if pick < cumulative
              chosen = name
              break
            end
          end

          order << chosen
          remaining.delete(chosen)
        end

        order
      end
    end
  end
end
