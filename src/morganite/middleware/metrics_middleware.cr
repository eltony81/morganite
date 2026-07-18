require "../server_middleware"
require "../metrics"

module Morganite
  class MetricsMiddleware
    include ServerMiddleware

    def call(job : Job, worker : Worker, queue : String, next_middleware : -> Nil)
      start = Time.utc
      next_middleware.call
      elapsed = Time.utc - start
      Metrics.observe("#{job.class}_duration", elapsed.total_seconds)
    rescue ex : Exception
      Metrics.increment("jobs_failed")
      raise ex
    end
  end
end
