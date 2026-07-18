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

  it "preserves timezone in next occurrence" do
    cron = Morganite::CronExpression.new("0 6 * * *")
    rome = Time::Location.load("Europe/Rome")
    from = Time.local(2026, 7, 13, 5, 0, 0, location: rome)
    next_time = cron.next(from)

    next_time.should eq(Time.local(2026, 7, 13, 6, 0, 0, location: rome))
    next_time.location.to_s.should eq("Europe/Rome")
  end

  it "rejects a day-of-month/month combination that can never occur" do
    # Regression test: before validating reachability at construction time,
    # an expression like "February 31st" would make `next` silently scan
    # ~5.2M minutes (its full 10-year search horizon) on every single call,
    # forever, since CronScheduler polls every 30s in an endless loop.
    expect_raises(Exception, /can never match/) do
      Morganite::CronExpression.new("0 0 31 2 *")
    end
  end

  it "still accepts a day-of-month/month combination that only occurs in some months" do
    # Day 30 doesn't exist in every month, but it's reachable (e.g. April),
    # so this must not be rejected by the reachability check.
    cron = Morganite::CronExpression.new("0 0 30 * *")
    from = Time.utc(2026, 1, 1, 0, 0, 0)
    next_time = cron.next(from)

    next_time.day.should eq(30)
  end
end
