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

class SurvivorWorker
  include Morganite::Worker

  @@processed = 0

  def self.processed
    @@processed
  end

  def self.clear
    @@processed = 0
  end

  def perform(args)
    @@processed += 1
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

  it "keeps processing jobs after a poisoned payload, instead of losing a worker fiber" do
    # Regression test: worker_loop used to have no rescue around
    # processor.process, so a bug that let an exception escape process
    # (or the malformed-JSON/unknown-worker cases fixed alongside this)
    # would permanently kill that worker fiber — silently shrinking
    # effective concurrency for the rest of the process's life.
    SurvivorWorker.clear
    redis = Morganite::RedisConnection.new_client
    redis.lpush("morganite:queue:default", "{not valid json at all")

    launcher = Morganite::Launcher.new(start_web: false)
    stopped = Channel(Nil).new
    spawn { launcher.run; stopped.send(nil) }

    job_count = 5
    job_count.times { SurvivorWorker.perform_async("go") }

    start = Time.utc
    until SurvivorWorker.processed >= job_count || (Time.utc - start).total_seconds > 5
      sleep 0.02.seconds
    end

    launcher.stop
    stopped.receive

    SurvivorWorker.processed.should eq(job_count)
  end
end
