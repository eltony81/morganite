require "../spec_helper"
require "http/client"
require "base64"

describe Morganite::Web do
  it "exposes dashboard, job detail, processes, health and metrics with auth and csrf" do
    original_username = Morganite.config.web_username
    original_password = Morganite.config.web_password

    Morganite.config.web_username = "admin"
    Morganite.config.web_password = "secret"

    Morganite::Metrics.reset
    job = Morganite::Client.enqueue("TestWorker", [JSON.parse("\"hello\"")], "default")
    job.should be_a(Morganite::Job)
    job = job.as(Morganite::Job)

    spawn { Morganite::Web.start(17_420) }
    sleep 0.5.seconds

    begin
      auth_header = "Basic #{Base64.strict_encode("admin:secret")}"

      # unauthenticated requests are rejected
      dashboard = HTTP::Client.get("http://localhost:17420/morganite")
      dashboard.status_code.should eq(401)

      dashboard = HTTP::Client.get("http://localhost:17420/morganite", headers: HTTP::Headers{"Authorization" => auth_header})
      dashboard.status_code.should eq(200)
      dashboard.body.should contain("Morganite Dashboard")

      detail = HTTP::Client.get("http://localhost:17420/morganite/jobs/#{job.jid}", headers: HTTP::Headers{"Authorization" => auth_header})
      detail.status_code.should eq(200)
      detail.body.should contain(job.jid)
      detail.body.should contain("TestWorker")

      processes = HTTP::Client.get("http://localhost:17420/morganite/processes", headers: HTTP::Headers{"Authorization" => auth_header})
      processes.status_code.should eq(200)
      processes.body.should contain("Processes")

      health = HTTP::Client.get("http://localhost:17420/health", headers: HTTP::Headers{"Authorization" => auth_header})
      health.status_code.should eq(200)
      health.body.should contain("\"status\":\"ok\"")

      metrics = HTTP::Client.get("http://localhost:17420/metrics", headers: HTTP::Headers{"Authorization" => auth_header})
      metrics.status_code.should eq(200)

      # CSRF protected POST without token is rejected
      no_csrf = HTTP::Client.post("http://localhost:17420/morganite/queues/default/delete", headers: HTTP::Headers{"Authorization" => auth_header})
      no_csrf.status_code.should eq(403)

      # Extract CSRF token from dashboard body
      csrf_match = dashboard.body.match(/name="_csrf" value="([^"]+)"/)
      csrf_match.should_not be_nil
      csrf_token = csrf_match.as(Regex::MatchData)[1]

      # CSRF protected POST with token succeeds
      with_csrf = HTTP::Client.post(
        "http://localhost:17420/morganite/queues/default/delete",
        headers: HTTP::Headers{"Authorization" => auth_header},
        form: {"_csrf" => csrf_token}
      )
      with_csrf.status_code.should eq(302)

      redis = Morganite::RedisConnection.new_client
      redis.llen("morganite:queue:default").should eq(0)
    ensure
      Morganite::Web.stop
      Morganite::Metrics.reset
      Morganite.config.web_username = original_username
      Morganite.config.web_password = original_password
    end
  end
end
