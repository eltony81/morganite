require "http/client"
require "json"

# JQCP Producer (docs/jqcp_tutorial.md). Deliberately does NOT `require
# "morganite"` -- a Producer is just a JSON-over-HTTP client calling the
# Broker's Worker API (Section 7's Enqueue RPC), the same RPC surface a
# Worker uses for Hello/Fetch/Ack. Nothing here is Morganite-specific; the
# same script could be Python or Node against the same Broker.

BROKER_URL   = ENV.fetch("JQCP_BROKER_URL", "http://localhost:7420")
WORKER_TOKEN = ENV.fetch("JQCP_WORKER_TOKEN", "worker-secret")
QUEUE        = ENV.fetch("JQCP_QUEUE", "jqcp-demo")

RECIPIENTS = ["alice@example.com", "bob@example.com", "carol@example.com"]

def enqueue(body : String) : JSON::Any
  resp = HTTP::Client.post(
    "#{BROKER_URL}/jqcp/v1/worker/enqueue",
    headers: HTTP::Headers{"Authorization" => "Bearer #{WORKER_TOKEN}", "Content-Type" => "application/json"},
    body: body
  )
  raise "enqueue failed: #{resp.status_code} #{resp.body}" unless resp.status_code == 200
  JSON.parse(resp.body)
end

count = (ARGV[0]? || "5").to_i

puts "Producer: submitting #{count} SendEmailJob to queue '#{QUEUE}' on #{BROKER_URL}"
count.times do |i|
  to = RECIPIENTS.sample
  subject = "Invoice ##{1000 + i}"
  result = enqueue(%({"job":{"type":"SendEmailJob","queue":"#{QUEUE}","args":[{"to":"#{to}","subject":"#{subject}"}],"retry":{"max":3}}}))
  puts "  enqueued jid=#{result["jid"]} to=#{to}"
end

puts "Producer: submitting 1 GenerateReportJob (long-running: timeoutSeconds=30, maxLeaseSeconds=3600)"
report = enqueue(%({"job":{"type":"GenerateReportJob","queue":"#{QUEUE}","args":[{"report":"annual-summary"}],"timeoutSeconds":30,"maxLeaseSeconds":3600}}))
puts "  enqueued jid=#{report["jid"]}"

puts "Producer: done."
