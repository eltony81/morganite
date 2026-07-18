require "json"

module Morganite
  module Logger
    enum Level
      DEBUG = 0
      INFO  = 1
      WARN  = 2
      ERROR = 3
    end

    @@level = Level::INFO
    @@json_format = false
    @@io : IO = STDERR

    def self.level=(level : Level)
      @@level = level
    end

    def self.json_format=(value : Bool)
      @@json_format = value
    end

    def self.io=(io : IO)
      @@io = io
    end

    def self.context(correlation_id : String? = nil, jid : String? = nil)
      Context.new(correlation_id, jid)
    end

    def self.debug(message : String, jid : String? = nil, correlation_id : String? = nil)
      log(Level::DEBUG, message, jid, correlation_id)
    end

    def self.info(message : String, jid : String? = nil, correlation_id : String? = nil)
      log(Level::INFO, message, jid, correlation_id)
    end

    def self.warn(message : String, jid : String? = nil, correlation_id : String? = nil)
      log(Level::WARN, message, jid, correlation_id)
    end

    def self.error(message : String, jid : String? = nil, correlation_id : String? = nil)
      log(Level::ERROR, message, jid, correlation_id)
    end

    private def self.log(level : Level, message : String, jid : String?, correlation_id : String?)
      return if level.value < @@level.value

      if @@json_format
        log_json(level, message, jid, correlation_id)
      else
        log_text(level, message, jid, correlation_id)
      end
    end

    private def self.log_json(level, message, jid, correlation_id)
      data = {
        "timestamp" => Time.utc.to_rfc3339,
        "level"     => level.to_s,
        "message"   => message,
      }
      data["jid"] = jid if jid
      data["correlation_id"] = correlation_id if correlation_id
      @@io.puts(data.to_json)
    end

    private def self.log_text(level, message, jid, correlation_id)
      parts = [Time.utc.to_rfc3339, level.to_s, message]
      parts << "jid=#{jid}" if jid
      parts << "correlation_id=#{correlation_id}" if correlation_id
      @@io.puts(parts.join(" | "))
    end

    class Context
      def initialize(@correlation_id : String? = nil, @jid : String? = nil)
      end

      def debug(message : String)
        Logger.debug(message, @jid, @correlation_id)
      end

      def info(message : String)
        Logger.info(message, @jid, @correlation_id)
      end

      def warn(message : String)
        Logger.warn(message, @jid, @correlation_id)
      end

      def error(message : String)
        Logger.error(message, @jid, @correlation_id)
      end
    end
  end
end
