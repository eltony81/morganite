require "kemal"
require "json"
require "html"
require "uri"
require "crypto/subtle"
require "./redis_connection"
require "./job"
require "./failures"
require "./job_index"
require "./metrics"
require "./logger"

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
            Logger.warn("web: unauthorized request to #{env.request.path} from #{env.request.remote_address}")
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

      # "Retry now" for a job currently waiting in the retry set: moves it
      # straight back onto its queue instead of waiting for RetryPoller.
      post "/morganite/retry/:jid/retry" do |env|
        halt env, status_code: 403, response: "Invalid CSRF token" unless csrf_valid?(env)
        jid = env.params.url["jid"]
        Morganite::Failures.retry_now(jid)
        env.redirect("/morganite")
      end

      post "/morganite/retry/:jid/delete" do |env|
        halt env, status_code: 403, response: "Invalid CSRF token" unless csrf_valid?(env)
        jid = env.params.url["jid"]
        Morganite::Failures.delete_retry(jid)
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
        Morganite::Failures.delete_scheduled(jid)
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
      String.build do |str|
        str << layout("Morganite Dashboard") do
          String.build do |inner|
            inner << %Q{<p><a href="/morganite/processes">Processes</a></p>}

            inner << "<h2>Queues</h2>"
            inner << "<table>"
            inner << "<tr><th>Name</th><th>Size</th><th>Actions</th></tr>"
            queue_counts.each do |name, size|
              inner << "<tr>"
              inner << %Q{<td><a href="/morganite/queues/#{h(path_segment(name))}">#{h(name)}</a></td>}
              inner << "<td>#{size}</td>"
              inner << "<td>#{action_form("/morganite/queues/#{h(path_segment(name))}/delete", "Delete all")}</td>"
              inner << "</tr>"
            end
            inner << "</table>"

            inner << section("Scheduled", "morganite:scheduled", "scheduled")
            inner << section("Retry", "morganite:retry", "retry")
            inner << section("Dead", "morganite:dead", "dead")
          end
        end
      end
    end

    private def self.render_queue(name : String)
      String.build do |str|
        str << layout("Queue: #{h(name)}") do
          String.build do |inner|
            inner << "<h2>Queue: #{h(name)}</h2>"
            inner << job_table(jobs_in_list("morganite:queue:#{name}"), "queue")
            inner << action_form("/morganite/queues/#{h(path_segment(name))}/delete", "Delete all")
          end
        end
      end
    end

    private def self.render_processes
      String.build do |str|
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
                inner << "<td>#{h(hostname)}</td>"
                inner << "<td>#{h(pid)}</td>"
                inner << "<td>#{count}</td>"
                inner << "</tr>"
              end
              inner << "</table>"
            end
          end
        end
      end
    end

    private def self.render_job_detail(jid : String)
      job, location = find_job(jid)
      kind = location_kind(location)

      String.build do |str|
        str << layout("Job: #{h(jid)}") do
          String.build do |inner|
            if job
              inner << "<h2>Job #{h(job.jid)}</h2>"
              inner << "<p><strong>Location:</strong> #{h(location)}</p>"
              inner << "<p><strong>Class:</strong> #{h(job.class)}</p>"
              inner << "<p><strong>Queue:</strong> #{h(job.queue)}</p>"
              inner << "<p><strong>Args:</strong> #{h(job.args.to_json)}</p>"
              inner << "<p><strong>Retry count:</strong> #{job.retry_count}</p>"
              inner << "<p><strong>Created at:</strong> #{Time.unix_ms((job.created_at * 1000).to_i64)}</p>"

              if failed_at = job.failed_at
                inner << "<p><strong>Failed at:</strong> #{Time.unix_ms((failed_at * 1000).to_i64)}</p>"
              end

              if error_message = job.error_message
                inner << "<p><strong>Error:</strong> #{h(error_message)}</p>"
              end

              if backtrace = job.error_backtrace
                inner << "<h3>Backtrace</h3>"
                inner << "<pre>#{h(backtrace.join("\n"))}</pre>"
              end

              inner << "<div>#{action_buttons(job, kind)}</div>"
            else
              inner << "<p>Job not found</p>"
            end
          end
        end
      end
    end

    private def self.section(title : String, key : String, location : String)
      String.build do |str|
        str << "<h2>#{h(title)}</h2>"
        str << job_table(jobs_in_set(key), location)
      end
    end

    private def self.job_table(jobs : Array(Job), location : String)
      return "<p>No jobs</p>" if jobs.empty?

      String.build do |str|
        str << "<table>"
        str << "<tr><th>JID</th><th>Class</th><th>Queue</th><th>Args</th><th>Actions</th></tr>"
        jobs.each do |job|
          str << "<tr>"
          str << %Q{<td><a href="/morganite/jobs/#{h(job.jid)}">#{h(job.jid)}</a></td>}
          str << "<td>#{h(job.class)}</td>"
          str << "<td>#{h(job.queue)}</td>"
          str << "<td>#{h(job.args.to_json)}</td>"
          str << "<td>#{action_buttons(job, location)}</td>"
          str << "</tr>"
        end
        str << "</table>"
      end
    end

    # Renders only the actions valid for the list a job actually lives in.
    # Jobs still waiting in a normal queue have no destructive per-row action;
    # scheduled/retry/dead jobs each map to the routes that operate on their
    # own Redis structure (see Failures.delete_scheduled/delete_retry/delete_dead
    # and Failures.retry_now/retry_dead).
    private def self.action_buttons(job : Job, location : String) : String
      case location
      when "dead"
        action_form("/morganite/dead/#{h(job.jid)}/retry", "Retry") +
          action_form("/morganite/dead/#{h(job.jid)}/delete", "Delete")
      when "retry"
        action_form("/morganite/retry/#{h(job.jid)}/retry", "Retry now") +
          action_form("/morganite/retry/#{h(job.jid)}/delete", "Delete")
      when "scheduled"
        action_form("/morganite/scheduled/#{h(job.jid)}/delete", "Delete")
      else
        ""
      end
    end

    private def self.action_form(path : String, label : String) : String
      %Q{<form method="post" action="#{path}" style="display:inline">#{csrf_tag}<button type="submit">#{h(label)}</button></form>}
    end

    private def self.location_kind(location : String) : String
      location.starts_with?("queue:") ? "queue" : location
    end

    private def self.layout(title : String, &)
      String.build do |str|
        str << "<!DOCTYPE html><html><head>"
        str << %Q{<meta charset="utf-8"><title>#{h(title)}</title>}
        str << "<style>body{font-family:sans-serif;margin:2em}table{border-collapse:collapse;width:100%}th,td{border:1px solid #ccc;padding:0.5em;text-align:left}form{display:inline;margin-right:0.5em}</style>"
        str << "</head><body>"
        str << %Q{<h1><a href="/morganite">Morganite</a></h1>}
        str << yield
        str << "</body></html>"
      end
    end

    # HTML-escapes any dynamic value before it's interpolated into a view.
    # Job class/queue/args, error messages/backtraces and URL params (queue
    # name, jid) all ultimately originate from application/job payloads and
    # must never be trusted as raw HTML.
    private def self.h(value) : String
      HTML.escape(value.to_s)
    end

    private def self.path_segment(value : String) : String
      URI.encode_path_segment(value)
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
        RedisConnection.scan_keys(redis, "morganite:queue:*").each do |key|
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
        result = redis.lrange(key, 0, -1)
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
        RedisConnection.scan_keys(redis, "morganite:processing:*").each do |key|
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
        if found = JobIndex.find_any(redis, jid)
          job, location = found
          return {job, location.sub("morganite:", "")}
        end

        RedisConnection.scan_keys(redis, "morganite:queue:*").each do |key|
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
      return false unless parts.size == 2

      # Compare both fields unconditionally (no `&&` short-circuit) and with a
      # constant-time comparison so neither field's correctness leaks via timing.
      user_ok = Crypto::Subtle.constant_time_compare(parts[0], username)
      pass_ok = Crypto::Subtle.constant_time_compare(parts[1], password)
      user_ok & pass_ok
    end

    private def self.csrf_tag : String
      token = @@csrf_token
      return "" unless token
      %Q{<input type="hidden" name="_csrf" value="#{h(token)}">}
    end

    private def self.csrf_valid?(env) : Bool
      token = @@csrf_token
      return true unless token

      submitted = env.params.body["_csrf"]?
      valid = !submitted.nil? && Crypto::Subtle.constant_time_compare(submitted, token)
      Logger.warn("web: invalid CSRF token on #{env.request.path} from #{env.request.remote_address}") unless valid
      valid
    end
  end
end
