require "morganite"
require "./workers/*"

module DemoApp
  REDIS_URL  = ENV.fetch("REDIS_URL", "redis://localhost:6379/0")
  QUEUE_NAME = ENV.fetch("QUEUE_NAME", "demo")

  Morganite.config = Morganite::Configuration.new(
    redis_url: REDIS_URL,
    queue: QUEUE_NAME,
    concurrency: ENV.fetch("CONCURRENCY", "5").to_i,
  )

  def self.enqueue(count : Int32)
    count.times do |i|
      Morganite::Client.enqueue("MyWorker", [JSON.parse({id: i + 1}.to_json)], QUEUE_NAME)
    end
    puts "Enqueued #{count} jobs to #{QUEUE_NAME}"
  end

  def self.work
    Morganite.start
    Morganite.wait
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
