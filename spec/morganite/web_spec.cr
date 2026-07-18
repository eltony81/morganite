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

    redis = Morganite::RedisConnection.new_client

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

      # Extract CSRF token from dashboard body, reused for every POST below
      csrf_match = dashboard.body.match(/name="_csrf" value="([^"]+)"/)
      csrf_match.should_not be_nil
      csrf_token = csrf_match.as(Regex::MatchData)[1]

      # Regression: job class/args/etc. must be HTML-escaped, not interpolated
      # raw into the dashboard (stored/reflected XSS)
      evil_job = Morganite::Client.build_job("<script>alert(1)</script>", [] of JSON::Any, "xss-test")
      redis.lpush(evil_job.queue_key, evil_job.to_json)

      evil_detail = HTTP::Client.get("http://localhost:17420/morganite/jobs/#{evil_job.jid}", headers: HTTP::Headers{"Authorization" => auth_header})
      evil_detail.status_code.should eq(200)
      evil_detail.body.should_not contain("<script>alert(1)</script>")
      evil_detail.body.should contain("&lt;script&gt;")

      # Regression: the "Delete" action on a Scheduled job used to call
      # Failures.delete_retry, which looks in the wrong Redis key (retry, not
      # scheduled) and silently no-ops.
      scheduled_job = Morganite::Client.build_job("TestWorker", [] of JSON::Any, "default")
      redis.zadd("morganite:scheduled", (Time.utc + 1.hour).to_unix, scheduled_job.to_json)

      del_scheduled = HTTP::Client.post(
        "http://localhost:17420/morganite/scheduled/#{scheduled_job.jid}/delete",
        headers: HTTP::Headers{"Authorization" => auth_header},
        form: {"_csrf" => csrf_token}
      )
      del_scheduled.status_code.should eq(302)
      redis.zscore("morganite:scheduled", scheduled_job.to_json).should be_nil

      # Regression: "Retry now" on a job waiting in the Retry set used to post
      # to a route that only searched the Dead set, so it was a silent no-op.
      retry_job = Morganite::Client.build_job("TestWorker", [] of JSON::Any, "default")
      redis.zadd("morganite:retry", (Time.utc + 1.hour).to_unix, retry_job.to_json)

      retry_now = HTTP::Client.post(
        "http://localhost:17420/morganite/retry/#{retry_job.jid}/retry",
        headers: HTTP::Headers{"Authorization" => auth_header},
        form: {"_csrf" => csrf_token}
      )
      retry_now.status_code.should eq(302)
      redis.zscore("morganite:retry", retry_job.to_json).should be_nil
      queued = redis.lrange(retry_job.queue_key, 0, -1).as(Array(Redis::Value))
      queued.map(&.as(String)).should contain(retry_job.to_json)

      # CSRF protected POST with token succeeds
      with_csrf = HTTP::Client.post(
        "http://localhost:17420/morganite/queues/default/delete",
        headers: HTTP::Headers{"Authorization" => auth_header},
        form: {"_csrf" => csrf_token}
      )
      with_csrf.status_code.should eq(302)

      redis.llen("morganite:queue:default").should eq(0)
    ensure
      Morganite::Web.stop
      Morganite::Metrics.reset
      Morganite.config.web_username = original_username
      Morganite.config.web_password = original_password
    end
  end
end
