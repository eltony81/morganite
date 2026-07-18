require "redis"
require "json"
require "./workers/*"

# TODO: once Morganite APIs are ready, replace the manual Redis queue logic
# with Morganite::Client and Morganite::Worker.
module DemoApp
  REDIS_URL   = ENV.fetch("REDIS_URL", "redis://localhost:6379/0")
  QUEUE_NAME  = ENV.fetch("QUEUE_NAME", "demo")
  COUNTER_KEY = "morganite:e2e:processed"
  QUEUE_KEY   = "queue:#{QUEUE_NAME}"

  def self.redis
    Redis::Client.new(URI.parse(REDIS_URL))
  end

  def self.enqueue(count : Int32)
    redis = self.redis
    count.times do |i|
      payload = {id: i + 1}.to_json
      redis.lpush(QUEUE_KEY, payload)
    end
    puts "Enqueued #{count} jobs to #{QUEUE_KEY}"
  end

  def self.work
    redis = self.redis
    puts "Worker started, listening on #{QUEUE_KEY}"

    loop do
      begin
        result = redis.brpop(QUEUE_KEY, timeout: 2)
        break unless result

        # result is an Array(Redis::Value) like ["queue:demo", "{\"id\":1}"]
        payload = JSON.parse(result[1].as(String))
        id = payload["id"].as_i

        redis.incr(COUNTER_KEY)
        puts "Processed job id=#{id}"
      rescue ex : Socket::ConnectError | IO::Error
        puts "Redis connection lost, shutting down worker: #{ex.message}"
        break
      end
    end
  end
end

case ARGV[0]?
when "enqueue"
  count = (ARGV[1]? || "100").to_i
  DemoApp.enqueue(count)
when "work", nil
  DemoApp.work
else
  STDERR.puts "Usage: demo_app [enqueue COUNT|work]"
  exit 1
end
