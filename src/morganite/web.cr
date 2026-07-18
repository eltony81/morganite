require "kemal"
require "json"
require "./redis_connection"
require "./job"
require "./failures"
require "./metrics"

module Morganite
  module Web
    @@routes_setup = false

    def self.start(port : Int32 = Morganite.config.web_port)
      Kemal.config.port = port
      Kemal.config.env = "production"
      setup_routes unless @@routes_setup
      Kemal.run
    end

    def self.stop
      Kemal.stop
    rescue
      # Kemal may already be stopped
    end

    private def self.setup_routes
      get "/" do |env|
        env.response.headers["Location"] = "/morganite"
        env.response.status_code = 302
      end

      get "/morganite" do
        render_dashboard
      end

      get "/morganite/queues/:name" do |env|
        name = env.params.url["name"]
        render_queue(name)
      end

      post "/morganite/queues/:name/delete" do |env|
        name = env.params.url["name"]
        Morganite.pool.with do |redis|
          redis.del("morganite:queue:#{name}")
        end
        env.redirect("/morganite")
      end

      post "/morganite/retries/:jid/retry" do |env|
        jid = env.params.url["jid"]
        Morganite::Failures.retry_dead(jid) || Morganite::Client.retry_dead(jid)
        env.redirect("/morganite")
      end

      post "/morganite/dead/:jid/retry" do |env|
        jid = env.params.url["jid"]
        Morganite::Failures.retry_dead(jid)
        env.redirect("/morganite")
      end

      post "/morganite/dead/:jid/delete" do |env|
        jid = env.params.url["jid"]
        Morganite::Failures.delete_dead(jid)
        env.redirect("/morganite")
      end

      post "/morganite/scheduled/:jid/delete" do |env|
        jid = env.params.url["jid"]
        Morganite::Failures.delete_retry(jid)
        env.redirect("/morganite")
      end

      get "/health" do |env|
        env.response.content_type = "application/json"
        healthy = redis_healthy?
        env.response.status_code = healthy ? 200 : 503
        {status: healthy ? "ok" : "error"}.to_json
      end

      get "/metrics" do |env|
        env.response.content_type = "text/plain; version=0.0.4"
        Morganite::Metrics.to_prometheus
      end
    end

    private def self.render_dashboard
      html = String.build do |str|
        str << layout("Morganite Dashboard") do
          String.build do |inner|
            inner << "<h2>Queues</h2>"
            inner << "<table>"
            inner << "<tr><th>Name</th><th>Size</th><th>Actions</th></tr>"
            queue_counts.each do |name, size|
              inner << "<tr>"
              inner << "<td><a href=\"/morganite/queues/#{name}\">#{name}</a></td>"
              inner << "<td>#{size}</td>"
              inner << %Q{<td><form method="post" action="/morganite/queues/#{name}/delete"><button type="submit">Delete all</button></form></td>}
              inner << "</tr>"
            end
            inner << "</table>"

            inner << section("Scheduled", "morganite:scheduled")
            inner << section("Retry", "morganite:retry")
            inner << section("Dead", "morganite:dead")
          end
        end
      end
      html
    end

    private def self.render_queue(name : String)
      html = String.build do |str|
        str << layout("Queue: #{name}") do
          String.build do |inner|
            inner << "<h2>Queue: #{name}</h2>"
            inner << job_table(jobs_in_list("morganite:queue:#{name}"))
            inner << %Q{<form method="post" action="/morganite/queues/#{name}/delete"><button type="submit">Delete all</button></form>}
          end
        end
      end
      html
    end

    private def self.section(title : String, key : String)
      String.build do |str|
        str << "<h2>#{title}</h2>"
        str << job_table(jobs_in_set(key))
      end
    end

    private def self.job_table(jobs : Array(Job))
      return "<p>No jobs</p>" if jobs.empty?

      String.build do |str|
        str << "<table>"
        str << "<tr><th>JID</th><th>Class</th><th>Queue</th><th>Args</th><th>Actions</th></tr>"
        jobs.each do |job|
          str << "<tr>"
          str << "<td>#{job.jid}</td>"
          str << "<td>#{job.class}</td>"
          str << "<td>#{job.queue}</td>"
          str << "<td>#{job.args.to_json}</td>"
          str << actions_for(job)
          str << "</tr>"
        end
        str << "</table>"
      end
    end

    private def self.actions_for(job : Job)
      String.build do |str|
        str << "<td>"
        str << %Q{<form method="post" action="/morganite/dead/#{job.jid}/retry" style="display:inline"><button type="submit">Retry</button></form>}
        str << %Q{<form method="post" action="/morganite/dead/#{job.jid}/delete" style="display:inline"><button type="submit">Delete</button></form>}
        str << %Q{<form method="post" action="/morganite/scheduled/#{job.jid}/delete" style="display:inline"><button type="submit">Delete</button></form>}
        str << "</td>"
      end
    end

    private def self.layout(title : String, &)
      String.build do |str|
        str << "<!DOCTYPE html><html><head>"
        str << %Q{<meta charset="utf-8"><title>#{title}</title>}
        str << "<style>body{font-family:sans-serif;margin:2em}table{border-collapse:collapse;width:100%}th,td{border:1px solid #ccc;padding:0.5em;text-align:left}form{display:inline;margin-right:0.5em}</style>"
        str << "</head><body>"
        str << %Q{<h1><a href="/morganite">Morganite</a></h1>}
        str << yield
        str << "</body></html>"
      end
    end

    private def self.redis_healthy? : Bool
      Morganite.pool.with do |redis|
        result = redis.ping
        result == "PONG"
      end
    rescue ex
      false
    end

    private def self.queue_counts : Hash(String, Int64)
      counts = {} of String => Int64
      Morganite.pool.with do |redis|
        redis.keys("morganite:queue:*").each do |key|
          next unless key.is_a?(String)
          name = key.sub("morganite:queue:", "")
          size = redis.llen(key)
          counts[name] = size.is_a?(Int64) ? size : 0_i64
        end
      end
      counts
    end

    private def self.jobs_in_list(key : String) : Array(Job)
      jobs = [] of Job
      Morganite.pool.with do |redis|
        len = redis.llen(key)
        len = 0_i64 unless len.is_a?(Int64)
        result = redis.lrange(key, 0, len - 1)
        return jobs unless result.is_a?(Array)
        result.each do |item|
          next unless item.is_a?(String)
          jobs << Job.from_json(item)
        end
      end
      jobs
    end

    private def self.jobs_in_set(key : String) : Array(Job)
      jobs = [] of Job
      Morganite.pool.with do |redis|
        result = redis.zrange(key, 0, -1)
        return jobs unless result.is_a?(Array)
        result.each do |item|
          next unless item.is_a?(String)
          jobs << Job.from_json(item)
        end
      end
      jobs
    end
  end
end
