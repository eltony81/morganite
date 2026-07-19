require "crypto/subtle"
require "../configuration"

module Morganite
  module Jqcp
    # JQCP Section 6: Bearer token call credentials, at minimum two distinct
    # scopes (jqcp:worker, jqcp:operator — split here into operator:read and
    # operator:write per the spec's SHOULD). A scope whose token isn't
    # configured is disabled entirely (fail closed, not open to anyone).
    module Auth
      enum Scope
        Worker
        OperatorRead
        OperatorWrite
      end

      def self.token_for(scope : Scope) : String?
        case scope
        in Scope::Worker
          Morganite.config.jqcp_worker_token
        in Scope::OperatorRead
          Morganite.config.jqcp_operator_read_token
        in Scope::OperatorWrite
          Morganite.config.jqcp_operator_write_token
        end
      end

      # Case-insensitive lookup rather than `headers["Authorization"]?`:
      # Kemal's `env.request.headers` is `HTTP::Headers`, already
      # case-insensitive by design, but this also duck-types against
      # quic.cr's `H3::Request#headers` (a plain `Hash(String, String)`,
      # case-sensitive) for the HTTP/3 Fetch path — RFC 9114 mandates
      # lowercase header names on the wire, so a literal `"Authorization"`
      # lookup would silently never match there. The two header types yield
      # different shapes when iterated (`HTTP::Headers` supports multiple
      # values per key, `{String, Array(String)}`; a plain Hash is just
      # `{String, String}`) — `raw_header_value` normalizes both.
      def self.bearer_token(env) : String?
        pair = env.request.headers.find { |key, _| key.downcase == "authorization" }
        return nil unless pair

        header = raw_header_value(pair[1])
        return nil unless header && header.starts_with?("Bearer ")

        header[7..]
      end

      private def self.raw_header_value(value) : String?
        value.is_a?(Array) ? value.first? : value
      end

      # True iff the request's Bearer token authorizes `scope`. A credential
      # holding operator:write also satisfies operator:read (Section 6 draws
      # write as the stronger scope, so treating it as a superset is the
      # natural reading — write access without read access would be useless).
      def self.authorized?(env, scope : Scope) : Bool
        presented = bearer_token(env)
        return false unless presented

        if configured = token_for(scope)
          return true if Crypto::Subtle.constant_time_compare(presented, configured)
        end

        if scope.operator_read? && (write_token = Morganite.config.jqcp_operator_write_token)
          return true if Crypto::Subtle.constant_time_compare(presented, write_token)
        end

        false
      end
    end
  end
end
