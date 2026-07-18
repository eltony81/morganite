require "./processor"
require "./redis_connection"

module Morganite
  class Launcher
    @running : Bool

    def initialize(
      @queues : Array(String) = [Morganite.config.queue],
      @concurrency : Int32 = Morganite.config.concurrency,
    )
      @redis = RedisConnection.new_client
      @running = true
      @shutdown = Channel(Nil).new
    end

    def run
      @concurrency.times do
        spawn { fetch_loop }
      end

      @shutdown.receive
      @running = false
    end

    def stop
      @shutdown.send(nil)
    end

    private def fetch_loop
      processor = Processor.new(@redis)

      while @running
        begin
          queue_keys = @queues.map { |queue| "morganite:queue:#{queue}" }
          result = @redis.brpop(queue_keys, timeout: 2)
          next unless result

          processor.process(result[1].as(String))
        rescue ex : Socket::ConnectError | IO::Error
          break unless @running
          sleep 0.5.seconds
        rescue ex : Exception
          # Job failed; continue fetching. Retry/dead handling is M2.
        end
      end
    end
  end
end
