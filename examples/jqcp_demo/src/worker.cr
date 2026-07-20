require "http/client"
require "json"
require "random"

# JQCP Worker (docs/jqcp_tutorial.md). Like producer.cr, deliberately does
# NOT `require "morganite"` -- a Worker is any process that speaks the
# Worker API's Hello/Fetch/Ack/Fail/RenewLease/Beat over JSON-over-HTTP.
# This is a different, independent consumer than Morganite's own native
# fiber-based Worker system (`include Morganite::Worker`); nothing here
# runs inside the Broker process.

BROKER_URL   = ENV.fetch("JQCP_BROKER_URL", "http://localhost:7420")
WORKER_TOKEN = ENV.fetch("JQCP_WORKER_TOKEN", "worker-secret")
QUEUE        = ENV.fetch("JQCP_QUEUE", "jqcp-demo")
WID          = ARGV[0]? || "worker-#{Random.rand(1000)}"
BEAT_EVERY   = 15.seconds

# Set by the tutorial to make a run terminate on its own instead of running
# forever like a real deployed Worker would -- unset (the default) means
# "run until Ctrl-C".
MAX_JOBS = ENV["JQCP_WORKER_MAX_JOBS"]?.try(&.to_i)

def post(path : String, body : String) : HTTP::Client::Response
  HTTP::Client.post(
    "#{BROKER_URL}#{path}",
    headers: HTTP::Headers{"Authorization" => "Bearer #{WORKER_TOKEN}", "Content-Type" => "application/json"},
    body: body
  )
end

def handle_send_email(jid : String, job : JSON::Any)
  to = job["args"][0]["to"].as_s
  sleep 0.5.seconds # simulate an SMTP call
  if Random.rand < 0.2
    puts "  -> simulated SMTP timeout sending to #{to}, reporting Fail"
    post("/jqcp/v1/worker/fail", %({"wid":"#{WID}","jid":"#{jid}","errtype":"SMTP::TimeoutError","message":"connection timed out"}))
  else
    puts "  -> sent to #{to}, Ack"
    post("/jqcp/v1/worker/ack", %({"wid":"#{WID}","jid":"#{jid}"}))
  end
end

def handle_generate_report(jid : String, job : JSON::Any)
  puts "  -> generating report (long job), RenewLease every 10s"
  3.times do
    sleep 10.seconds
    renewed = JSON.parse(post("/jqcp/v1/worker/renew_lease", %({"wid":"#{WID}","jid":"#{jid}"})).body)
    if renewed["killed"].as_bool
      puts "  -> job was killed externally, stopping"
      return
    end
    puts "  -> lease renewed"
  end
  post("/jqcp/v1/worker/ack", %({"wid":"#{WID}","jid":"#{jid}"}))
  puts "  -> report done, Ack"
end

Signal::INT.trap do
  puts "\nWorker[#{WID}]: shutting down"
  exit 0
end

puts "Worker[#{WID}]: Hello (queues=[#{QUEUE}])"
hello = post("/jqcp/v1/worker/hello", %({"wid":"#{WID}","queues":["#{QUEUE}"],"concurrency":1}))
raise "hello failed: #{hello.status_code} #{hello.body}" unless hello.status_code == 200

last_beat = Time.utc
processed = 0

loop do
  if Time.utc - last_beat > BEAT_EVERY
    post("/jqcp/v1/worker/beat", %({"wid":"#{WID}"}))
    last_beat = Time.utc
  end

  resp = post("/jqcp/v1/worker/fetch", %({"wid":"#{WID}"}))
  if resp.status_code == 204
    next # nothing eligible within the bounded poll (docs/jqcp_conformance.md's Fetch fallback) -- try again
  elsif resp.status_code != 200
    puts "Worker[#{WID}]: fetch error #{resp.status_code} #{resp.body}"
    sleep 1.second
    next
  end

  job = JSON.parse(resp.body)
  jid = job["jid"].as_s
  type = job["type"].as_s
  puts "Worker[#{WID}]: fetched #{type} jid=#{jid}"

  case type
  when "SendEmailJob"
    handle_send_email(jid, job)
  when "GenerateReportJob"
    handle_generate_report(jid, job)
  else
    puts "Worker[#{WID}]: unknown job type #{type}, failing it"
    post("/jqcp/v1/worker/fail", %({"wid":"#{WID}","jid":"#{jid}","errtype":"UnknownJobType","message":"no handler for #{type}"}))
  end

  processed += 1
  if max_jobs = MAX_JOBS
    break if processed >= max_jobs
  end
end

puts "Worker[#{WID}]: processed #{processed} job(s), exiting"
