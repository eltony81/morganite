require "socket"

module Morganite
  module Statsd
    def self.increment(name : String, value : Int64 = 1_i64, tags : Hash(String, String)? = nil)
      send("#{name}:#{value}|c", tags)
    end

    def self.histogram(name : String, value : Float64, tags : Hash(String, String)? = nil)
      send("#{name}:#{value}|h", tags)
    end

    private def self.send(payload : String, tags : Hash(String, String)? = nil)
      addr = Morganite.config.statsd_addr
      return unless addr

      host, port_str = addr.split(":", 2)
      port = port_str.to_i

      final_payload = if tags && !tags.empty?
                        tag_str = tags.map { |k, v| "#{k}:#{v}" }.join(",")
                        "#{payload}|##{tag_str}"
                      else
                        payload
                      end

      spawn do
        begin
          socket = UDPSocket.new
          socket.connect(host, port)
          socket.send(final_payload)
          socket.close
        rescue ex
          # Silently drop statsd errors to avoid impacting job processing
        end
      end
    end
  end
end
