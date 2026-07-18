require "redis"
require "./logger"

module Morganite
  module RedisConnection
    def self.new_client
      Redis::Client.new(URI.parse(Morganite.config.redis_url))
    end

    # Enumerates keys matching `pattern` via SCAN rather than KEYS, so a large
    # keyspace doesn't block the Redis server for every other client while
    # this runs. Shared by anything that needs to enumerate a key family
    # (the web dashboard, OrphanReaper, ...).
    def self.scan_keys(redis : Redis::Client, pattern : String) : Array(String)
      keys = [] of String
      cursor = "0"

      loop do
        result = redis.scan(cursor, match: pattern, count: 200)
        break unless result.is_a?(Array) && result.size == 2

        next_cursor = result[0]
        batch = result[1]
        break unless next_cursor.is_a?(String) && batch.is_a?(Array)

        batch.each { |item| keys << item if item.is_a?(String) }

        cursor = next_cursor
        break if cursor == "0"
      end

      keys
    end
  end

  class RedisPool
    # Below this, a wait for a pooled connection isn't worth logging.
    POOL_WAIT_WARN_THRESHOLD = 50.milliseconds

    def initialize(@size : Int32, &factory : -> Redis::Client)
      @pool = Channel(Redis::Client).new(@size)
      @size.times { @pool.send(factory.call) }
    end

    def with(& : Redis::Client -> T) : T forall T
      start = Time.instant
      client = @pool.receive
      wait = Time.instant - start
      if wait > POOL_WAIT_WARN_THRESHOLD
        Logger.warn("redis pool: waited #{wait.total_milliseconds.round(2)}ms for a connection (pool size #{@size})")
      end

      yield client
    ensure
      @pool.send(client) if client
    end
  end

  @@pool : RedisPool? = nil

  def self.pool : RedisPool
    @@pool ||= RedisPool.new(Morganite.config.concurrency + 2) { RedisConnection.new_client }
  end

  def self.reset_pool!
    @@pool = RedisPool.new(Morganite.config.concurrency + 2) { RedisConnection.new_client }
  end
end
