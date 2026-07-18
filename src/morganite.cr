require "./morganite/version"
require "./morganite/configuration"
require "./morganite/redis_connection"
require "./morganite/job"
require "./morganite/registry"
require "./morganite/worker"
require "./morganite/client"
require "./morganite/processor"
require "./morganite/launcher"

module Morganite
  @@launcher : Launcher? = nil

  def self.start
    @@launcher = Launcher.new
    if launcher = @@launcher
      spawn { launcher.run }
    end
  end

  def self.stop
    @@launcher.try(&.stop)
  end

  def self.wait
    loop { sleep 1.second }
  end
end
