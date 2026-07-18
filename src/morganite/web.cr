require "kemal"
require "json"
require "./redis_connection"
require "./job"
require "./failures"
require "./metrics"

require "random/secure"
require "base64"

module Morganite
  module Web
    @@routes_setup = false
    @@csrf_token : String? = nil

    def self.start(port : Int32 = Morganite.config.web_port)
      Kemal.config.port = port
      Kemal.config.env = "production"
      @@csrf_token = Random::Secure.hex(32)
      setup_routes unless @@routes_setup
      Kemal.run
    end

    def self.stop
      Kemal.stop
    rescue
      # Kemal may already be stopped
    end

    private def self.setup_routes
      before_all do |env|
        if auth_required? && protected_path?(env.request.path)
          unless authorized?(env)
            env.response.headers["WWW-Authenticate"] = "Basic realm=\"Morganite\""
            halt env, status_code: 401, response: "Unauthorized"
          end
        end
      end

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

      get "/morganite/processes" do
        render_processes
      end

      get "/morganite/jobs/:jid" do |env|
        jid = env.params.url["jid"]
        render_job_detail(jid)
      end

      post "/morganite/queues/:name/delete" do |env|
        halt env, status_code: 403, response: "Invalid CSRF token" unless csrf_valid?(env)
        name = env.params.url["name"]
        Morganite.pool.with do |redis|
          redis.del("morganite:queue:#{name}")
        end
        env.redirect("/morganite")
      end

      post "/morganite/retries/:jid/retry" do |env|
        halt env, status_code: 403, response: "Invalid CSRF token" unless csrf_valid?(env)
        jid = env.params.url["jid"]
        Morganite::Failures.retry_dead(jid) || Morganite::Client.retry_dead(jid)
        env.redirect("/morganite")
      end

      post "/morganite/dead/:jid/retry" do |env|
        halt env, status_code: 403, response: "Invalid CSRF token" unless csrf_valid?(env)
        jid = env.params.url["jid"]
        Morganite::Failures.retry_dead(jid)
        env.redirect("/morganite")
      end

      post "/morganite/dead/:jid/delete" do |env|
        halt env, status_code: 403, response: "Invalid CSRF token" unless csrf_valid?(env)
        jid = env.params.url["jid"]
        Morganite::Failures.delete_dead(jid)
        env.redirect("/morganite")
      end

      post "/morganite/scheduled/:jid/delete" do |env|
        halt env, status_code: 403, response: "Invalid CSRF token" unless csrf_valid?(env)
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
            inner << %Q{<p><a href="/morganite/processes">Processes</a></p>}

            inner << "<h2>Queues</h2>"
            inner << "<table>"
            inner << "<tr><th>Name</th><th>Size</th><th>Actions</th></tr>"
            queue_counts.each do |name, size|
              inner << "<tr>"
              inner << "<td><a href=\"/morganite/queues/#{name}\">#{name}</a></td>"
              inner << "<td>#{size}</td>"
              inner << %Q{<td><form method="post" action="/morganite/queues/#{name}/delete">#{csrf_tag}<button type="submit">Delete all</button></form></td>}
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
            inner << %Q{<form method="post" action="/morganite/queues/#{name}/delete">#{csrf_tag}<button type="submit">Delete all</button></form>}
          end
        end
      end
      html
    end

    private def self.render_processes
      html = String.build do |str|
        str << layout("Morganite Processes") do
          String.build do |inner|
            inner << "<h2>Processes</h2>"
            processes = processing_processes
            if processes.empty?
              inner << "<p>No active processes</p>"
            else
              inner << "<table>"
              inner << "<tr><th>Hostname</th><th>PID</th><th>In-flight jobs</th></tr>"
              processes.each do |hostname, pid, count|
                inner << "<tr>"
                inner << "<td>#{hostname}</td>"
                inner << "<td>#{pid}</td>"
                inner << "<td>#{count}</td>"
                inner << "</tr>"
              end
              inner << "</table>"
            end
          end
        end
      end
      html
    end

    private def self.render_job_detail(jid : String)
      job, location = find_job(jid)

      html = String.build do |str|
        str << layout("Job: #{jid}") do
          String.build do |inner|
            if job
              inner << "<h2>Job #{job.jid}</h2>"
              inner << "<p><strong>Location:</strong> #{location}</p>"
              inner << "<p><strong>Class:</strong> #{job.class}</p>"
              inner << "<p><strong>Queue:</strong> #{job.queue}</p>"
              inner << "<p><strong>Args:</strong> #{job.args.to_json}</p>"
              inner << "<p><strong>Retry count:</strong> #{job.retry_count}</p>"
              inner << "<p><strong>Created at:</strong> #{Time.unix_ms((job.created_at * 1000).to_i64)}</p>"

              if failed_at = job.failed_at
                inner << "<p><strong>Failed at:</strong> #{Time.unix_ms((failed_at * 1000).to_i64)}</p>"
              end

              if error_message = job.error_message
                inner << "<p><strong>Error:</strong> #{error_message}</p>"
              end

              if backtrace = job.error_backtrace
                inner << "<h3>Backtrace</h3>"
                inner << "<pre>#{backtrace.join("\n")}</pre>"
              end

              inner << actions_for(job)
            else
              inner << "<p>Job not found</p>"
            end
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
          str << %Q{<td><a href="/morganite/jobs/#{job.jid}">#{job.jid}</a></td>}
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
        str << %Q{<form method="post" action="/morganite/dead/#{job.jid}/retry" style="display:inline">#{csrf_tag}<button type="submit">Retry</button></form>}
        str << %Q{<form method="post" action="/morganite/dead/#{job.jid}/delete" style="display:inline">#{csrf_tag}<button type="submit">Delete</button></form>}
        str << %Q{<form method="post" action="/morganite/scheduled/#{job.jid}/delete" style="display:inline">#{csrf_tag}<button type="submit">Delete</button></form>}
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

    private def self.processing_processes : Array(Tuple(String, String, Int64))
      processes = [] of Tuple(String, String, Int64)
      Morganite.pool.with do |redis|
        redis.keys("morganite:processing:*").each do |key|
          next unless key.is_a?(String)
          parts = key.sub("morganite:processing:", "").split(":")
          next unless parts.size == 2
          count = redis.llen(key)
          count = count.is_a?(Int64) ? count : 0_i64
          processes << {parts[0], parts[1], count}
        end
      end
      processes
    end

    private def self.find_job(jid : String) : Tuple(Job?, String)
      Morganite.pool.with do |redis|
        redis.keys("morganite:queue:*").each do |key|
          next unless key.is_a?(String)
          result = redis.lrange(key, 0, -1)
          next unless result.is_a?(Array)
          result.each do |item|
            next unless item.is_a?(String)
            job = Job.from_json(item)
            return {job, key.sub("morganite:", "")} if job.jid == jid
          end
        end

        ["morganite:scheduled", "morganite:retry", "morganite:dead"].each do |key|
          result = redis.zrange(key, 0, -1)
          next unless result.is_a?(Array)
          result.each do |item|
            next unless item.is_a?(String)
            job = Job.from_json(item)
            return {job, key.sub("morganite:", "")} if job.jid == jid
          end
        end
      end

      {nil, ""}
    end

    private def self.auth_required? : Bool
      !!(Morganite.config.web_username && Morganite.config.web_password)
    end

    private def self.protected_path?(path : String) : Bool
      path == "/" || path.starts_with?("/morganite") || path == "/health" || path == "/metrics"
    end

    private def self.authorized?(env) : Bool
      username = Morganite.config.web_username
      password = Morganite.config.web_password
      return true unless username && password

      auth_header = env.request.headers["Authorization"]?
      return false unless auth_header

      return false unless auth_header.starts_with?("Basic ")
      decoded = Base64.decode_string(auth_header[6..])
      parts = decoded.split(":", 2)
      parts.size == 2 && parts[0] == username && parts[1] == password
    end

    private def self.csrf_tag : String
      token = @@csrf_token
      return "" unless token
      %Q{<input type="hidden" name="_csrf" value="#{token}">}
    end

    private def self.csrf_valid?(env) : Bool
      token = @@csrf_token
      return true unless token

      submitted = env.params.body["_csrf"]?
      submitted == token
    end
  end
end
