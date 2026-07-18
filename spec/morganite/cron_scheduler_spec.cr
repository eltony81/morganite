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
    redis.zcard(Morganite::ScheduledPoller::SCHEDULED_KEY).should eq(1)
  end
end
