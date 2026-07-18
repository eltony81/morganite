require "../client_middleware"
require "../logger"

module Morganite
  class LoggingClientMiddleware
    include ClientMiddleware

    def call(job : Job, next_middleware : -> Nil)
      Logger.info("enqueueing job #{job.class} to #{job.queue}", jid: job.jid)
      next_middleware.call
    end
  end
end
