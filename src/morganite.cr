require "./morganite/version"
require "./morganite/configuration"
require "./morganite/redis_connection"
require "./morganite/job"
require "./morganite/registry"
require "./morganite/worker"
require "./morganite/client"
require "./morganite/retry"
require "./morganite/failures"
require "./morganite/retry_poller"
require "./morganite/scheduled_poller"
require "./morganite/cron"
require "./morganite/cron_scheduler"
require "./morganite/server_middleware"
require "./morganite/client_middleware"
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
