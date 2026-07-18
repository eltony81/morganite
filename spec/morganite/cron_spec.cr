require "../spec_helper"

describe Morganite::CronExpression do
  it "parses a specific time" do
    cron = Morganite::CronExpression.new("30 9 15 7 1")
    from = Time.utc(2026, 7, 13, 0, 0, 0) # Monday 13 July
    next_time = cron.next(from)

    next_time.minute.should eq(30)
    next_time.hour.should eq(9)
    next_time.day.should eq(15)
    next_time.month.should eq(7)
  end

  it "parses every minute" do
    cron = Morganite::CronExpression.new("* * * * *")
    from = Time.utc(2026, 7, 13, 12, 0, 0)
    next_time = cron.next(from)

    next_time.should eq(Time.utc(2026, 7, 13, 12, 1, 0))
  end

  it "parses step expressions" do
    cron = Morganite::CronExpression.new("*/15 * * * *")
    from = Time.utc(2026, 7, 13, 12, 10, 0)
    next_time = cron.next(from)

    next_time.should eq(Time.utc(2026, 7, 13, 12, 15, 0))
  end

  it "parses lists and ranges" do
    cron = Morganite::CronExpression.new("0 9-17 * * 1-5")
    from = Time.utc(2026, 7, 13, 12, 0, 0) # Monday
    next_time = cron.next(from)

    next_time.should eq(Time.utc(2026, 7, 13, 13, 0, 0))
  end
end
