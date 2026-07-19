require "json"

module Morganite
  module Jqcp
    # JQCP Section 5.3: every non-OK response carries a stable, machine-
    # readable "reason" token plus a "domain" and free-form "metadata". This
    # Broker is JSON-over-HTTP (see docs/jqcp_conformance.md), so HTTP status
    # codes stand in for gRPC status codes; REASON_STATUS follows Section
    # 5.3's gRPC-status mapping translated to the nearest HTTP equivalent.
    module Errors
      DOMAIN = "jqcp.morganite"

      REASON_STATUS = {
        "invalid_job"               => 400, # INVALID_ARGUMENT
        "duplicate_idempotency_key" => 409, # ALREADY_EXISTS
        "job_not_found"             => 404, # NOT_FOUND
        "invalid_state_transition"  => 409, # FAILED_PRECONDITION
        "queue_not_found"           => 404, # NOT_FOUND
        "queue_paused"              => 409, # FAILED_PRECONDITION
        "unauthorized"              => 401, # UNAUTHENTICATED
        "forbidden"                 => 403, # PERMISSION_DENIED
      }

      def self.status_for(reason : String) : Int32
        REASON_STATUS.fetch(reason, 500)
      end

      def self.body(reason : String, metadata : Hash(String, String) = {} of String => String) : String
        {
          "reason"   => reason,
          "domain"   => DOMAIN,
          "metadata" => metadata,
        }.to_json
      end

      # Kemal's `halt` is a macro that expands to a bare `next`, so it only
      # works called directly inside a route block — not from a regular
      # method. Handler methods therefore return `String | Rejection`, and
      # only the thin route block itself pattern-matches and calls `halt`.
      record Rejection, reason : String, metadata : Hash(String, String) = {} of String => String
    end
  end
end
