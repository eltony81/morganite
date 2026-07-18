require "../spec_helper"

class UniqueWhileExecutingWorker
  include Morganite::Worker
  unique :while_executing

  @@running = 0
  @@max_running = 0
  @@mutex = Mutex.new
  @@barrier = Channel(Nil).new(2)
  @@started = Channel(Nil).new(2)

  def perform(args)
    @@mutex.lock
    @@running += 1
    @@max_running = Math.max(@@max_running, @@running)
    @@mutex.unlock
    @@started.send(nil)

    @@barrier.receive

    @@mutex.lock
    @@running -= 1
    @@mutex.unlock
  end

  def self.reset
    @@mutex.lock
    @@running = 0
    @@max_running = 0
    @@mutex.unlock
  end

  # Blocks until at least one `perform` call has actually started (i.e. won
  # the while_executing lock), instead of guessing with a fixed sleep — the
  # lock-losing call resolves via the same Redis round trip and has settled
  # by the time this returns, so this is enough to know both attempts are done.
  def self.wait_for_start(timeout = 2.seconds)
    select
    when @@started.receive
    when timeout(timeout)
      raise "timed out waiting for UniqueWhileExecutingWorker to start"
    end
  end

  def self.max_running
    @@mutex.lock
    value = @@max_running
    @@mutex.unlock
    value
  end

  def self.release
    @@barrier.send(nil)
  end
end

class UniqueUntilExecutedWorker
  include Morganite::Worker
  unique :until_executed

  @@calls = 0
  @@mutex = Mutex.new

  def perform(args)
    @@mutex.lock
    @@calls += 1
    call = @@calls
    @@mutex.unlock

    raise "boom" if call == 1
  end

  def self.calls
    @@mutex.lock
    value = @@calls
    @@mutex.unlock
    value
  end

  def self.reset
    @@mutex.lock
    @@calls = 0
    @@mutex.unlock
  end
end

class UniqueUntilExpiredWorker
  include Morganite::Worker
  unique :until_expired, ttl: 1

  def perform(args)
  end
end

class UniqueManualUnlockWorker
  include Morganite::Worker
  unique :until_executed

  def perform(args)
  end
end

describe Morganite::UniqueJobs do
  before_each do
    UniqueWhileExecutingWorker.reset
    UniqueUntilExecutedWorker.reset
  end

  it "prevents concurrent execution with while_executing" do
    UniqueWhileExecutingWorker.perform_async(1)

    redis = Morganite::RedisConnection.new_client
    redis.llen("morganite:queue:default").should eq(1)
    payload = redis.rpop("morganite:queue:default").as(String)

    done = Channel(Nil).new(2)

    spawn { Morganite::Processor.new.process(payload); done.send(nil) }
    spawn { Morganite::Processor.new.process(payload); done.send(nil) }

    UniqueWhileExecutingWorker.wait_for_start
    UniqueWhileExecutingWorker.max_running.should eq(1)

    UniqueWhileExecutingWorker.release
    UniqueWhileExecutingWorker.release

    done.receive
    done.receive

    UniqueWhileExecutingWorker.max_running.should eq(1)
  end

  it "blocks duplicate enqueue with until_executed until the job succeeds" do
    job = UniqueUntilExecutedWorker.perform_async(1)
    job.should be_a(Morganite::Job)

    redis = Morganite::RedisConnection.new_client
    payload = redis.rpop("morganite:queue:default").as(String)

    processor = Morganite::Processor.new
    processor.process(payload)

    redis.zcard(Morganite::Failures::RETRY_KEY).should eq(1)

    duplicate = UniqueUntilExecutedWorker.perform_async(1)
    duplicate.should be_nil

    retry_items = redis.zrange(Morganite::Failures::RETRY_KEY, 0, 0).as(Array(Redis::Value))
    retry_payload = retry_items[0].as(String)
    redis.zrem(Morganite::Failures::RETRY_KEY, retry_payload)
    redis.lpush(job.as(Morganite::Job).queue_key, retry_payload)

    processor.process(retry_payload)

    redis.zcard(Morganite::Failures::RETRY_KEY).should eq(0)
    UniqueUntilExecutedWorker.calls.should eq(2)

    duplicate2 = UniqueUntilExecutedWorker.perform_async(1)
    duplicate2.should be_a(Morganite::Job)
  end

  it "blocks duplicate enqueue with until_expired within the TTL" do
    job = UniqueUntilExpiredWorker.perform_async(1)
    job.should be_a(Morganite::Job)

    duplicate = UniqueUntilExpiredWorker.perform_async(1)
    duplicate.should be_nil

    sleep 1.1.seconds

    later = UniqueUntilExpiredWorker.perform_async(1)
    later.should be_a(Morganite::Job)
  end

  it "unlocks a job manually via UniqueJobs.unlock" do
    job = UniqueManualUnlockWorker.perform_async(1)
    job.should be_a(Morganite::Job)

    duplicate = UniqueManualUnlockWorker.perform_async(1)
    duplicate.should be_nil

    Morganite::UniqueJobs.unlock(job.as(Morganite::Job))

    duplicate2 = UniqueManualUnlockWorker.perform_async(1)
    duplicate2.should be_a(Morganite::Job)
  end

  it "does not release a lock that a different job instance now owns" do
    # Regression test: unlock used to be an unconditional DEL. If job A's
    # lock TTL expired and job B legitimately acquired the same unique key
    # in the meantime, job A finishing late and calling unlock would delete
    # job B's active lock, breaking the mutual-exclusion guarantee.
    job_a = Morganite::Client.build_job("UniqueManualUnlockWorker", [] of JSON::Any, "default")
    Morganite::UniqueJobs.lock(job_a).should be_true

    job_b = Morganite::Client.build_job("UniqueManualUnlockWorker", [] of JSON::Any, "default")
    redis = Morganite::RedisConnection.new_client
    redis.set(Morganite::UniqueJobs.lock_key(job_a), job_b.jid)

    Morganite::UniqueJobs.unlock(job_a)

    redis.get(Morganite::UniqueJobs.lock_key(job_a)).should eq(job_b.jid)
  end

  it "releases the lock when the job still owns it" do
    job = Morganite::Client.build_job("UniqueManualUnlockWorker", [] of JSON::Any, "default")
    Morganite::UniqueJobs.lock(job).should be_true

    Morganite::UniqueJobs.unlock(job)

    redis = Morganite::RedisConnection.new_client
    redis.get(Morganite::UniqueJobs.lock_key(job)).should be_nil
  end
end
