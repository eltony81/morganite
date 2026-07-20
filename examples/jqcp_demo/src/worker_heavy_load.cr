require "http/client"
require "json"

# E2E scenario (docs/jqcp_tutorial.md, "Un worker con un carico di
# elaborazione pesante"): a Worker doing REAL heavy CPU computation (not
# just sleep) for much longer than the Job's timeoutSeconds, calling
# RenewLease between chunks. Proves the Lease survives genuine sustained
# work, not just I/O waits.

BROKER_URL   = ENV.fetch("JQCP_BROKER_URL", "http://localhost:7420")
WORKER_TOKEN = ENV.fetch("JQCP_WORKER_TOKEN", "worker-secret")
WID          = ARGV[0]? || "worker-heavy-1"
JID          = ARGV[1]? || raise "usage: worker_heavy_load <wid> <jid>"
CHUNKS       = (ENV["HEAVY_CHUNKS"]? || "5").to_i
PRIMES_UPTO  = (ENV["HEAVY_PRIMES_UPTO"]? || "3000000").to_i

def post(path : String, body : String) : HTTP::Client::Response
  HTTP::Client.post(
    "#{BROKER_URL}#{path}",
    headers: HTTP::Headers{"Authorization" => "Bearer #{WORKER_TOKEN}", "Content-Type" => "application/json"},
    body: body
  )
end

# Genuine CPU-bound work: trial-division prime count up to PRIMES_UPTO.
# Deliberately not the sieve (which would be memory-bound and too fast) --
# this burns real wall-clock CPU time comparable to the timeoutSeconds
# we're testing against.
def burn_cpu(upto : Int32) : Int32
  count = 0
  (2..upto).each do |candidate|
    is_prime = true
    i = 2
    while i * i <= candidate
      if candidate % i == 0
        is_prime = false
        break
      end
      i += 1
    end
    count += 1 if is_prime
  end
  count
end

puts "Worker[#{WID}]: heavy-load run on jid=#{JID}, #{CHUNKS} chunks of trial-division primes up to #{PRIMES_UPTO}"

CHUNKS.times do |i|
  t0 = Time.instant
  primes = burn_cpu(PRIMES_UPTO)
  elapsed = Time.instant - t0
  puts "  chunk #{i + 1}/#{CHUNKS}: found #{primes} primes in #{elapsed.total_seconds.round(2)}s (real CPU work, not sleep)"

  renew_resp = post("/jqcp/v1/worker/renew_lease", %({"wid":"#{WID}","jid":"#{JID}"}))
  if renew_resp.status_code != 200
    puts "  -> RenewLease rejected: #{renew_resp.status_code} #{renew_resp.body} -- Lease is gone, stopping without Ack"
    exit 1
  end
  renewed = JSON.parse(renew_resp.body)
  if renewed["killed"].as_bool
    puts "  -> RenewLease says killed:true -- Lease is gone, stopping without Ack"
    exit 1
  end
  puts "  -> RenewLease: killed:false, Lease extended"
end

ack = post("/jqcp/v1/worker/ack", %({"wid":"#{WID}","jid":"#{JID}"}))
puts "Worker[#{WID}]: Ack -> #{ack.status_code} #{ack.body}"
