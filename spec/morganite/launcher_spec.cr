require "../spec_helper"

class SlowShutdownWorker
  include Morganite::Worker

  @@started = Channel(Nil).new
  @@release = Channel(Nil).new
  @@done = Channel(Nil).new

  def self.started
    @@started
  end

  def self.release
    @@release.send(nil)
  end

  def self.wait
    @@done.receive
  end

  def perform(args : Array(JSON::Any))
    @@started.send(nil)
    @@release.receive
    @@done.send(nil)
  end
end

describe Morganite::Launcher do
  it "gracefully shuts down and finishes the in-flight job" do
    launcher = Morganite::Launcher.new(start_web: false)
    stopped = Channel(Nil).new
    spawn { launcher.run; stopped.send(nil) }

    SlowShutdownWorker.perform_async("test")
    SlowShutdownWorker.started.receive

    stop_done = Channel(Nil).new
    spawn { launcher.stop; stop_done.send(nil) }

    SlowShutdownWorker.release
    SlowShutdownWorker.wait

    select
    when stop_done.receive
      # shutdown completed after the job finished
    when timeout(2.seconds)
      fail "shutdown did not complete in time"
    end

    stopped.receive
  end
end
