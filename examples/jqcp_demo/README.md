# JQCP Demo

Companion code for [`docs/jqcp_tutorial.md`](../../docs/jqcp_tutorial.md) —
build/deploy instructions for each program are in the tutorial itself, not
repeated here. Operator is played by plain `curl`, not code.

| File | Role |
|------|------|
| `src/broker.cr` | Broker entrypoint — requires workers then runs `Morganite::CLI.run`. |
| `src/workers/jqcp_demo_worker.cr` | Native Morganite worker registered for the broker's own fetch loop. |
| `src/producer.cr` | Producer — submits Jobs over JSON-HTTP. No `morganite` dependency. |
| `src/worker.cr` | Worker — Hello/Fetch/Ack/Fail/RenewLease/Beat loop. No `morganite` dependency. |
| `src/worker_http3.cr` | Bonus: Worker using the experimental HTTP/3 push Fetch (`quic.cr` directly). |
| `src/worker_heavy_load.cr` | E2E scenario: real (non-`sleep`) CPU load with periodic `RenewLease`. |
| `src/worker_no_renew.cr` | E2E scenario: a Worker that never renews — proves `LeaseReaper` reclaims on its own. |

```bash
shards install
crystal build src/broker.cr -o bin/broker

export MORGANITE_REDIS_URL=redis://localhost:6379/0
export MORGANITE_QUEUE=default
export MORGANITE_WEB_PORT=7420
export MORGANITE_JQCP_WORKER_TOKEN=worker-secret
export MORGANITE_JQCP_OPERATOR_READ_TOKEN=read-secret
export MORGANITE_JQCP_OPERATOR_WRITE_TOKEN=write-secret

./bin/broker
```

Then follow the tutorial from step 2 onward.
