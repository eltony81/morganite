require "../spec_helper"
require "http/client"

describe Morganite::Web do
  it "exposes dashboard, health and metrics" do
    Morganite::Metrics.reset
    Morganite::Client.enqueue("TestWorker", [JSON.parse("\"hello\"")], "default")
    Morganite::Metrics.increment("jobs_processed", 7)

    spawn { Morganite::Web.start(17420) }
    sleep 0.5.seconds

    begin
      dashboard = HTTP::Client.get("http://localhost:17420/morganite")
      dashboard.status_code.should eq(200)
      dashboard.body.should contain("Morganite Dashboard")
      dashboard.body.should contain("default")
      dashboard.body.should contain("1</td>")

      health = HTTP::Client.get("http://localhost:17420/health")
      health.status_code.should eq(200)
      health.body.should contain("\"status\":\"ok\"")

      metrics = HTTP::Client.get("http://localhost:17420/metrics")
      metrics.status_code.should eq(200)
      metrics.headers["Content-Type"].should contain("text/plain")
      metrics.body.should contain("morganite_jobs_processed 7")

      HTTP::Client.post("http://localhost:17420/morganite/queues/default/delete")

      redis = Morganite::RedisConnection.new_client
      redis.llen("morganite:queue:default").should eq(0)
    ensure
      Morganite::Web.stop
      Morganite::Metrics.reset
    end
  end
end
