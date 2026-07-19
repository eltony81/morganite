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
    property backtrace : Bool | Int32
    property? dead : Bool
    property unique : String?
    property unique_for : Int32
    property bid : String?
    property wid : String?
    property step_index : Int32
    property error_message : String?
    property error_type : String?
    property error_backtrace : Array(String)?
    property failed_at : Float64?
    property retried_at : Float64?

    # JQCP (Section 4.2) fields. `priority` is stored as a hint but does not
    # reorder a queue's underlying Redis LIST (Section 8.1 only mandates
    # ordering *across* queues via a priority strategy, Section 10 — not
    # intra-queue reordering). `timeout_seconds` is opt-in Lease tracking
    # (Section 8.8): 0 means the job isn't Lease-tracked and only the
    # existing process-level OrphanReaper covers it.
    property priority : Int32
    property timeout_seconds : UInt32
    property idempotency_key : String?

    def initialize(
      @class : String,
      @args : Array(JSON::Any) = [] of JSON::Any,
      @queue : String = Morganite.config.queue,
      @retry : Bool | Int32 = true,
      @backtrace : Bool | Int32 = true,
      @dead : Bool = true,
      @unique : String? = nil,
      @unique_for : Int32 = 300,
      @bid : String? = nil,
      @wid : String? = nil,
      @step_index : Int32 = 0,
      @jid : String = UUID.random.to_s,
      @created_at : Float64 = Time.utc.to_unix_f,
      @enqueued_at : Float64? = nil,
      @retry_count : Int32 = 0,
      @error_message : String? = nil,
      @error_type : String? = nil,
      @error_backtrace : Array(String)? = nil,
      @failed_at : Float64? = nil,
      @retried_at : Float64? = nil,
      @priority : Int32 = 0,
      @timeout_seconds : UInt32 = 0,
      @idempotency_key : String? = nil,
    )
    end

    def queue_key
      "morganite:queue:#{queue}"
    end
  end
end
