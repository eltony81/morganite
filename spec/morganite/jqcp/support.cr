# ameba:disable Lint/SpecFilename
require "http/server"

# Mutating the existing Configuration instance's properties directly (not
# via `Morganite.config = ...`) intentionally skips `validate!`/logger
# resync — neither applies to these fields — and avoids resetting every
# other spec file's config expectations the way constructing a whole new
# Configuration would (see CLAUDE.md's note on this distinction).
Morganite.config.jqcp_worker_token = "test-worker-token"
Morganite.config.jqcp_operator_read_token = "test-read-token"
Morganite.config.jqcp_operator_write_token = "test-write-token"

module Morganite::Jqcp::SpecSupport
  def self.fake_env(body : String? = nil, bearer : String? = nil) : HTTP::Server::Context
    headers = HTTP::Headers.new
    headers["Content-Type"] = "application/json" if body
    headers["Authorization"] = "Bearer #{bearer}" if bearer
    request = HTTP::Request.new("POST", "/", headers, body)
    HTTP::Server::Context.new(request, HTTP::Server::Response.new(IO::Memory.new))
  end
end
