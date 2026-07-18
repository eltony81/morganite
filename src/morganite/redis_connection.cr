require "redis"

module Morganite
  module RedisConnection
    def self.new_client
      Redis::Client.new(URI.parse(Morganite.config.redis_url))
    end
  end

  class RedisPool
    def initialize(@size : Int32, &factory : -> Redis::Client)
      @pool = Channel(Redis::Client).new(@size)
      @size.times { @pool.send(factory.call) }
    end

    def with(& : Redis::Client -> T) : T forall T
      client = @pool.receive
      yield client
    ensure
      @pool.send(client) if client
    end
  end

  class_getter pool : RedisPool do
    RedisPool.new(Morganite.config.concurrency + 2) { RedisConnection.new_client }
  end
end
