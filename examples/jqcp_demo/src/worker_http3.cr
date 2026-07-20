require "quic"
require "http/client"
require "json"

# Bonus JQCP Worker variant (docs/jqcp_tutorial.md): uses the experimental
# HTTP/3 Fetch transport (docs/jqcp_conformance.md's "HTTP/3 Fetch
# (experimental)") instead of the bounded-polling `worker.cr`. Jobs arrive
# as real HTTP/3 Server Push the instant a Producer enqueues them, no
# polling loop. Requires the Broker built with `-Dmorganite_http3` and
# `MORGANITE_JQCP_HTTP3_ENABLED=true` -- see the tutorial's bonus section
# for why this stays a separate, explicitly-opted-into example rather than
# the default.
#
# Ack/Fail/Hello/Beat/RenewLease still go over plain JSON-HTTP (unchanged
# from worker.cr) -- only Fetch itself moves transport.

JSON_BROKER_URL = ENV.fetch("JQCP_BROKER_URL", "http://localhost:7420")
HTTP3_HOST      = ENV.fetch("JQCP_HTTP3_HOST", "127.0.0.1")
HTTP3_PORT      = ENV.fetch("JQCP_HTTP3_PORT", "7444").to_i
WORKER_TOKEN    = ENV.fetch("JQCP_WORKER_TOKEN", "worker-secret")
QUEUE           = ENV.fetch("JQCP_QUEUE", "jqcp-demo")
WID             = ARGV[0]? || "worker-http3-#{Random.rand(1000)}"

def post(path : String, body : String) : HTTP::Client::Response
  HTTP::Client.post(
    "#{JSON_BROKER_URL}#{path}",
    headers: HTTP::Headers{"Authorization" => "Bearer #{WORKER_TOKEN}", "Content-Type" => "application/json"},
    body: body
  )
end

def handle_job(jid : String, type : String, job : JSON::Any)
  puts "  [push] #{type} jid=#{jid}"
  case type
  when "SendEmailJob"
    to = job["args"][0]["to"].as_s
    sleep 0.5.seconds
    puts "  -> sent to #{to}, Ack"
    post("/jqcp/v1/worker/ack", %({"wid":"#{WID}","jid":"#{jid}"}))
  else
    puts "  -> unknown job type #{type}, failing it"
    post("/jqcp/v1/worker/fail", %({"wid":"#{WID}","jid":"#{jid}","errtype":"UnknownJobType","message":"no handler for #{type}"}))
  end
end

puts "Worker[#{WID}]: Hello (queues=[#{QUEUE}]) over JSON-HTTP"
hello = post("/jqcp/v1/worker/hello", %({"wid":"#{WID}","queues":["#{QUEUE}"],"concurrency":1}))
raise "hello failed: #{hello.status_code} #{hello.body}" unless hello.status_code == 200

config = QUIC::Config.new
config.initial_max_data = 10_000_000_u64
config.initial_max_stream_data_bidi_local = 1_000_000_u64
config.initial_max_stream_data_bidi_remote = 1_000_000_u64
config.initial_max_streams_bidi = 100_u64
config.initial_max_streams_uni = 100_u64
config.initial_max_stream_data_uni = 1_000_000_u64

client = H3::Client.new(HTTP3_HOST, HTTP3_PORT, config)
client.on_push = ->(_push_id : UInt64, _headers : Hash(String, String), body : Bytes) {
  job = JSON.parse(String.new(body))
  handle_job(job["jid"].as_s, job["type"].as_s, job)
  nil
}
client.accept_pushes!(10_u64)

windows = (ENV["JQCP_WORKER_HTTP3_WINDOWS"]? || "5").to_i
puts "Worker[#{WID}]: opening #{windows} HTTP/3 Fetch window(s) on udp/#{HTTP3_PORT}"

windows.times do |i|
  _headers, body, _trailers = client.get("/jqcp/v1/worker/fetch?wid=#{WID}", {"authorization" => "Bearer #{WORKER_TOKEN}"})
  puts "Worker[#{WID}]: window #{i + 1}/#{windows} ended (#{String.new(body)})"
end

client.close
puts "Worker[#{WID}]: exiting"
