require "json"
require "uuid"

module Morganite
  class Job
    include JSON::Serializable

    property jid : String
    property class : String
    property args : Array(JSON::Any)
    property queue : String
    property created_at : Float64
    property enqueued_at : Float64?
    property retry : Bool | Int32
    property retry_count : Int32
    property error_message : String?
    property error_backtrace : Array(String)?
    property failed_at : Float64?
    property retried_at : Float64?

    def initialize(
      @class : String,
      @args : Array(JSON::Any) = [] of JSON::Any,
      @queue : String = Morganite.config.queue,
      @retry : Bool | Int32 = true,
      @jid : String = UUID.random.to_s,
      @created_at : Float64 = Time.utc.to_unix_f,
      @enqueued_at : Float64? = nil,
      @retry_count : Int32 = 0,
      @error_message : String? = nil,
      @error_backtrace : Array(String)? = nil,
      @failed_at : Float64? = nil,
      @retried_at : Float64? = nil,
    )
    end

    def queue_key
      "morganite:queue:#{queue}"
    end
  end
end
