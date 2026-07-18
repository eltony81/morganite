require "../spec_helper"

class CustomBackoffWorker
  include Morganite::Worker

  def retry_in(retry_count : Int32) : Int32
    retry_count * 10
  end

  def perform(args)
  end
end

describe Morganite::Retry do
  it "computes a backoff with positive jitter" do
    Morganite::Retry.backoff_for(Morganite::Job.new(class: "W", retry_count: 0)).should be >= 15
    Morganite::Retry.backoff_for(Morganite::Job.new(class: "W", retry_count: 1)).should be >= 16
    Morganite::Retry.backoff_for(Morganite::Job.new(class: "W", retry_count: 2)).should be >= 31
  end

  it "allows a worker to override retry backoff" do
    job = Morganite::Job.new(class: "CustomBackoffWorker", retry_count: 3)
    Morganite::Retry.backoff_for(job).should eq(30)
  end

  it "returns max retries from job config" do
    no_retry = Morganite::Job.new(class: "W", retry: false)
    Morganite::Retry.max_retries_for(no_retry).should eq(0)

    limited = Morganite::Job.new(class: "W", retry: 3)
    Morganite::Retry.max_retries_for(limited).should eq(3)

    default = Morganite::Job.new(class: "W", retry: true)
    Morganite::Retry.max_retries_for(default).should eq(Morganite::Retry::DEFAULT_MAX_RETRIES)
  end

  it "decides whether a job should be retried" do
    no_retry = Morganite::Job.new(class: "W", retry: false, retry_count: 0)
    Morganite::Retry.retry_job?(no_retry).should be_false

    limited = Morganite::Job.new(class: "W", retry: 3, retry_count: 2)
    Morganite::Retry.retry_job?(limited).should be_true

    exhausted = Morganite::Job.new(class: "W", retry: 3, retry_count: 3)
    Morganite::Retry.retry_job?(exhausted).should be_false
  end
end
