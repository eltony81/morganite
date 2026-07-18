require "redis"

module Morganite
  module RedisConnection
    def self.new_client
      Redis::Client.new(URI.parse(Morganite.config.redis_url))
    end
  end
end
