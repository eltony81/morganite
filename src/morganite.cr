require "./morganite/version"
require "./morganite/configuration"
require "./morganite/redis_connection"
require "./morganite/job"
require "./morganite/job_index"
require "./morganite/registry"
require "./morganite/unique_jobs"
require "./morganite/worker"
require "./morganite/client"
require "./morganite/batch"
require "./morganite/rate_limiter"
require "./morganite/workflow"
require "./morganite/retry"
require "./morganite/failures"
require "./morganite/jqcp/job_state"
require "./morganite/jqcp/idempotency"
require "./morganite/jqcp/queue_control"
require "./morganite/jqcp/worker_session"
require "./morganite/jqcp/errors"
require "./morganite/jqcp/auth"
require "./morganite/jqcp/lease"
require "./morganite/jqcp/lease_reaper"
require "./morganite/jqcp/worker_api"
require "./morganite/jqcp/operator_api"
require "./morganite/jqcp/http3_fetch_server"
require "./morganite/retry_poller"
require "./morganite/scheduled_poller"
require "./morganite/cron"
require "./morganite/cron_scheduler"
require "./morganite/poller_script"
require "./morganite/orphan_reaper"
require "./morganite/server_middleware"
require "./morganite/client_middleware"
require "./morganite/middleware/logging_middleware"
require "./morganite/middleware/metrics_middleware"
require "./morganite/middleware/datadog_middleware"
require "./morganite/middleware/logging_client_middleware"
require "./morganite/middleware/metadata_client_middleware"
require "./morganite/middleware/tracing_client_middleware"
require "./morganite/hooks"
require "./morganite/logger"
require "./morganite/metrics"
require "./morganite/processor"
require "./morganite/launcher"

module Morganite
  @@launcher : Launcher? = nil
  @@stopped = Channel(Nil).new

  def self.start
    launcher = Launcher.new
    @@launcher = launcher
    spawn { launcher.run }
  end

  def self.stop
    @@launcher.try(&.stop)
    @@stopped.send(nil) rescue nil
  end

  def self.wait
    @@stopped.receive
  end

  Logger.level = Logger::Level.parse(config.log_level.upcase)
  Logger.json_format = config.log_format == "json"
end
