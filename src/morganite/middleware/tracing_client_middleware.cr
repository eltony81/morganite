require "../client_middleware"
require "../logger"

module Morganite
  class TracingClientMiddleware
    include ClientMiddleware

    def call(job : Job, next_middleware : -> Nil)
      trace_id = Random::Secure.hex(8)
      Logger.info("tracing enqueue #{trace_id}", jid: job.jid)
      next_middleware.call
    end
  end
end
