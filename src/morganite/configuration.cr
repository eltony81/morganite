module Morganite
  class Configuration
    property redis_url : String
    property queue : String
    property concurrency : Int32
    property web_port : Int32
    property log_level : String
    property log_format : String

    def initialize(
      @redis_url : String = ENV.fetch("MORGANITE_REDIS_URL", "redis://localhost:6379/0"),
      @queue : String = ENV.fetch("MORGANITE_QUEUE", "default"),
      @concurrency : Int32 = ENV.fetch("MORGANITE_CONCURRENCY", "5").to_i,
      @web_port : Int32 = ENV.fetch("MORGANITE_WEB_PORT", "7420").to_i,
      @log_level : String = ENV.fetch("MORGANITE_LOG_LEVEL", "info"),
      @log_format : String = ENV.fetch("MORGANITE_LOG_FORMAT", "text"),
    )
    end
  end

  class_property config : Configuration = Configuration.new
end
