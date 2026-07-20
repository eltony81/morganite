require "http/client"
require "json"

# E2E scenario (docs/jqcp_tutorial.md, "Un worker che non rinnova mai la
# Lease"): a Worker that fetches a Job and then goes silent -- no
# RenewLease, no Beat, no Ack/Fail -- simulating a genuinely stuck/crashed
# Worker. Proves the Broker's LeaseReaper reclaims the Job on its own once
# timeoutSeconds elapses, independent of anything the Worker does or
# doesn't do afterward.

BROKER_URL   = ENV.fetch("JQCP_BROKER_URL", "http://localhost:7420")
WORKER_TOKEN = ENV.fetch("JQCP_WORKER_TOKEN", "worker-secret")
WID          = ARGV[0]? || "worker-stuck-1"
JID          = ARGV[1]? || raise "usage: worker_no_renew <wid> <jid>"
SILENT_FOR   = (ENV["STUCK_SILENT_SECONDS"]? || "20").to_i

puts "Worker[#{WID}]: holding Lease on jid=#{JID}, going silent for #{SILENT_FOR}s (no RenewLease, no Beat, no Ack/Fail)"
sleep SILENT_FOR.seconds
puts "Worker[#{WID}]: done being silent, exiting without ever reporting back"
