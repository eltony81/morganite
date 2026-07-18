require "../server_middleware"

module Morganite
  # Example Datadog APM-like middleware.
  # In a real deployment you would emit spans to the Datadog agent.
  class DatadogMiddleware
    include ServerMiddleware

    def call(job : Job, worker : Worker, queue : String, next_middleware : -> Nil)
      # Placeholder: replace with real Datadog tracer call.
      # span_name = "morganite.job"
      # tags = "worker:#{job.class},queue:#{queue},jid:#{job.jid}"
      # Datadog::Tracing.trace(span_name, tags: tags) do
      next_middleware.call
      # end
    end
  end
end
