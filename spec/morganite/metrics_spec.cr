require "../spec_helper"

describe Morganite::Metrics do
  before_each do
    Morganite::Metrics.reset
  end

  it "increments counters" do
    Morganite::Metrics.increment("jobs_processed", 2)
    Morganite::Metrics.increment("jobs_processed", 3)

    output = Morganite::Metrics.to_prometheus
    output.should contain("morganite_jobs_processed 5")
  end

  it "observes histogram values" do
    [0.01, 0.05, 0.2, 1.5].each do |value|
      Morganite::Metrics.observe("my_job_duration", value)
    end

    output = Morganite::Metrics.to_prometheus
    output.should contain("morganite_my_job_duration_duration_seconds_bucket{le=\"0.25\"} 3")
    output.should contain("morganite_my_job_duration_duration_seconds_count 4")
    output.should contain("morganite_my_job_duration_duration_seconds_sum 1.76")
  end

  it "resets all metrics" do
    Morganite::Metrics.increment("jobs_processed")
    Morganite::Metrics.observe("my_job_duration", 0.1)
    Morganite::Metrics.reset

    output = Morganite::Metrics.to_prometheus
    output.should be_empty
  end
end
