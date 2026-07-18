require "../spec_helper"

describe Morganite::CronScheduler do
  before_each do
    Morganite::Cron.clear
  end

  it "schedules cron jobs that are due" do
    # Schedule a job that matches every minute.
    Morganite::Cron.register("FailingWorker", "* * * * *")

    scheduler = Morganite::CronScheduler.new(poll_interval: 0.1.seconds)
    spawn { scheduler.run }
    sleep 0.3.seconds
    scheduler.stop

    redis = Morganite::RedisConnection.new_client
    # The scheduler may poll across a minute boundary, so we allow one or more
    # scheduled instances instead of expecting exactly one.
    redis.zcard(Morganite::ScheduledPoller::SCHEDULED_KEY).as(Int64).should be >= 1
  end
end
