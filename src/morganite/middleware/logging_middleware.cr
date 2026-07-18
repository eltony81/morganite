require "../server_middleware"
require "../logger"

module Morganite
  class LoggingMiddleware
    include ServerMiddleware

    def call(job : Job, worker : Worker, queue : String, next_middleware : -> Nil)
      log = Logger.context(jid: job.jid)
      log.info("starting job #{job.class} on #{queue}")
      begin
        next_middleware.call
        log.info("finished job #{job.class}")
      rescue ex : Exception
        log.error("job failed: #{ex.class}: #{ex.message}")
        raise ex
      end
    end
  end
end
