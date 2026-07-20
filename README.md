<img src="docs/assets/logo-lockup.svg" alt="Morganite" width="420">

[![CI](https://github.com/eltony81/morganite/actions/workflows/ci.yml/badge.svg)](https://github.com/eltony81/morganite/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)

Morganite is a background job processing library for [Crystal](https://crystal-lang.org/), inspired by [Sidekiq](https://sidekiq.org/).

It uses **Redis** as a backend and provides a Ruby-like developer experience while leveraging Crystal’s compiled, fiber-based concurrency. Morganite is designed for production use with built-in observability, reliability patterns and a lightweight embedded dashboard.

## Features

- Worker-based job processing with Redis-backed queues
- Retries with exponential backoff and jitter
- Scheduled jobs and cron expressions
- Dead-letter queue with manual retry/delete
- Built-in Web UI (Kemal) with basic auth
- Server and client middleware + lifecycle hooks
- Health checks and Prometheus metrics
- Unique jobs (`while_executing`, `until_executed`, `until_expired`)
- Batches with success/complete callbacks
- Per-worker rate limiting
- Job workflows (chained jobs)
- CLI with config file, env vars and inline execution

## Quick start

Make sure Redis is running, then build and start the broker using the built-in CLI binary:

```bash
shards build morganite
./bin/morganite
```

The broker is now processing jobs from the `default` queue and serving the Web UI on `http://localhost:7420`.

Alternatively, implement the broker in your own entrypoint file. This is useful when you want to wire configuration directly in code or bundle your own workers:

```crystal
# src/broker.cr
require "morganite"
require "./workers/my_worker"

Morganite.config = Morganite::Configuration.new(
  redis_url: "redis://localhost:6379/0",
  queue: "default",
  concurrency: 10,
  web_port: 7420,
  log_level: "info",
)

Morganite.start
Morganite.wait
```

Build and run it:

```bash
crystal build src/broker.cr -o bin/broker
./bin/broker
```

If you still want CLI flag support, replace `Morganite.start` / `Morganite.wait` with `require "morganite/cli"` and `Morganite::CLI.run`:

```crystal
require "morganite"
require "morganite/cli"
require "./workers/my_worker"

Morganite::CLI.run
```

## Installation

Add this to your `shard.yml`:

```yaml
dependencies:
  morganite:
    github: eltony81/morganite
```

Then run:

```bash
shards install
```

## Usage

> For a complete walkthrough of every feature — batches, workflows, rate limiting, middleware, unique jobs, Docker deploy — see [`docs/usage.md`](docs/usage.md) (in Italian).

```crystal
require "morganite"

class MyWorker
  include Morganite::Worker

  def perform(args)
    puts "Processing #{args}"
  end
end

# Enqueue a job from Crystal
MyWorker.perform_async("hello", "world")

# Or enqueue the same job over HTTP via the JQCP endpoint:
# curl -X POST http://localhost:7420/jqcp/v1/worker/enqueue \
#   -H "Authorization: Bearer worker-secret" \
#   -H "Content-Type: application/json" \
#   -d '{"job":{"type":"MyWorker","queue":"default","args":["hello","world"]}}'
```

## Two worker models

Morganite supports two ways to execute jobs. Choose the one that fits your architecture.

### 1. Native Morganite workers

The worker class is compiled into the broker process and executed by Morganite's own fiber-based fetch loop. This is the Sidekiq-like model and the simplest way to get started.

```crystal
require "morganite"

class SendEmailWorker
  include Morganite::Worker

  def perform(args)
    to = args[0]["to"].as_s
    puts "Sending email to #{to}"
  end
end

# Enqueue from anywhere with Redis access
SendEmailWorker.perform_async({to: "user@example.com"}.to_json)
```

Start the broker:

```bash
crystal build src/broker.cr -o bin/broker
./bin/broker
```

The broker fetches jobs from Redis and calls `perform` inside its own process.

### 2. External JQCP workers

The broker only manages queues over Redis and exposes a JSON-over-HTTP API. Workers are separate processes — even written in other languages — that register with the broker and pull jobs via HTTP.

Producer enqueues a job via HTTP:

```crystal
require "http/client"

resp = HTTP::Client.post(
  "http://localhost:7420/jqcp/v1/worker/enqueue",
  headers: HTTP::Headers{
    "Authorization" => "Bearer worker-secret",
    "Content-Type"  => "application/json",
  },
  body: %({
    "job": {
      "type": "SendEmailJob",
      "queue": "jqcp-demo",
      "args": [{"to":"user@example.com"}]
    }
  })
)
```

External worker registers and fetches:

```crystal
require "http/client"
require "json"

BROKER_URL   = "http://localhost:7420"
WORKER_TOKEN = "worker-secret"
WID          = "worker-1"

# Register with the broker
HTTP::Client.post(
  "#{BROKER_URL}/jqcp/v1/worker/hello",
  headers: HTTP::Headers{"Authorization" => "Bearer #{WORKER_TOKEN}", "Content-Type" => "application/json"},
  body: %({"wid":"#{WID}","queues":["jqcp-demo"],"concurrency":1})
)

# Pull a job
resp = HTTP::Client.post(
  "#{BROKER_URL}/jqcp/v1/worker/fetch",
  headers: HTTP::Headers{"Authorization" => "Bearer #{WORKER_TOKEN}", "Content-Type" => "application/json"},
  body: %({"wid":"#{WID}"})
)

job = JSON.parse(resp.body)
puts "Processing #{job["type"]}"

# Confirm completion
HTTP::Client.post(
  "#{BROKER_URL}/jqcp/v1/worker/ack",
  headers: HTTP::Headers{"Authorization" => "Bearer #{WORKER_TOKEN}", "Content-Type" => "application/json"},
  body: %({"wid":"#{WID}","jid":"#{job["jid"]}"})
)
```

### Choosing between the two

| | Native `Morganite::Worker` | External JQCP worker |
|---|---|---|
| Process location | Inside the broker | Separate process |
| Language | Crystal only | Any language |
| Deployment | Single compiled binary | Broker + worker services |
| Network location | Same machine as broker | Can be on different machines |
| Complexity | Low | Higher (HTTP API) |
| Best for | Simple, self-contained apps | Polyglot systems, remote workers, large scale |

See [`docs/jqcp_tutorial.md`](docs/jqcp_tutorial.md) for a complete JQCP walkthrough.

## Scheduled and cron jobs

```crystal
# Run once in 5 minutes
MyWorker.perform_in(5.minutes, "later")

# Run at a specific time
MyWorker.perform_at(Time.utc(2026, 12, 25, 9, 0, 0), "christmas")

# Run every minute (cron)
class RecurringWorker
  include Morganite::Worker
  cron "* * * * *"

  def perform(args)
    puts "Tick"
  end
end
```

## Running the processor

```bash
shards build morganite
./bin/morganite
```

The processor fetches jobs from `morganite:queue:default`, executes them concurrently, retries failed ones and schedules future/cron jobs.

### CLI options

```text
-c, --config PATH       Load configuration from YAML or JSON file
    --concurrency N     Number of concurrent workers
    --queue NAME        Queue to process
-v, --verbose           Enable debug logging
    --web-only          Start only the Web UI
    --inline 'WORKER ARGS'  Run a worker inline with JSON args
    --version           Show version
-h, --help              Show this help
```

Examples:

```bash
# Run with a config file
./bin/morganite --config config/morganite.yml

# Run a single queue with more workers
./bin/morganite --queue critical --concurrency 10

# Execute a worker inline for debugging
./bin/morganite --inline 'MyWorker ["hello","world"]'

# Start only the Web UI
./bin/morganite --web-only
```

Because Morganite is a compiled Crystal binary, workers must be required at compile time. Create a small entrypoint file in your application:

```crystal
# src/my_app_worker.cr
require "morganite"
require "./workers/my_worker"

Morganite.start
Morganite.wait
```

Then build and run your own binary:

```bash
crystal build src/my_app_worker.cr -o bin/my_app_worker
./bin/my_app_worker
```

## Configuration

Morganite can be configured via environment variables or a YAML/JSON file. Environment variables override file values.

### Environment variables

| Variable | Default | Description |
|----------|---------|-------------|
| `MORGANITE_REDIS_URL` | `redis://localhost:6379/0` | Redis connection URL |
| `MORGANITE_QUEUE` | `default` | Default queue name |
| `MORGANITE_CONCURRENCY` | `5` | Number of concurrent workers |
| `MORGANITE_WEB_PORT` | `7420` | Web UI port |
| `MORGANITE_LOG_LEVEL` | `info` | Log level (`debug`, `info`, `warn`, `error`) |
| `MORGANITE_LOG_FORMAT` | `text` | Log format (`text`, `json`) |
| `MORGANITE_DEAD_MAX_JOBS` | `10000` | Max dead jobs to keep |
| `MORGANITE_DEAD_TIMEOUT_IN_SECONDS` | `15552000` | Dead job retention |
| `MORGANITE_WEB_USERNAME` | - | Web UI basic auth username |
| `MORGANITE_WEB_PASSWORD` | - | Web UI basic auth password |
| `MORGANITE_SECRET_KEY` | random | Secret key for CSRF |
| `MORGANITE_STATSD_ADDR` | - | StatsD collector address |
| `MORGANITE_ORPHAN_REAPER_POLL_INTERVAL_SECONDS` | `30` | How often `OrphanReaper` scans for jobs left behind by a process that died without a graceful shutdown |

### Configuration file

```yaml
# config/morganite.yml
redis_url: redis://localhost:6379/0
queue: default
concurrency: 5
web_port: 7420
log_level: info
log_format: text
```

Load it with:

```bash
./bin/morganite --config config/morganite.yml
```

## Web UI

Morganite embeds a dashboard on port `7420` (configurable via `MORGANITE_WEB_PORT`):

```bash
./bin/morganite
# open http://localhost:7420/morganite
```

The dashboard shows queues, scheduled, retry and dead jobs, and allows you to delete or retry them.

## JQCP

Morganite implements a semantic conformance layer for JQCP (`draft-difluri-jqcp-02`), a gRPC-based job-queue control protocol — exposed as JSON-over-HTTP under `/jqcp/v1/` (no viable Crystal gRPC-streaming stack exists yet; see [`docs/jqcp_conformance.md`](docs/jqcp_conformance.md) for the full rationale and endpoint reference). Enable it with:

```bash
export MORGANITE_JQCP_WORKER_TOKEN=...
export MORGANITE_JQCP_OPERATOR_READ_TOKEN=...
export MORGANITE_JQCP_OPERATOR_WRITE_TOKEN=...
```

See [`docs/jqcp_tutorial.md`](docs/jqcp_tutorial.md) for a hands-on walkthrough of all four JQCP roles (Broker, Producer, Worker, Operator) against a real running Broker.

### HTTP/3 Fetch (experimental)

Morganite also offers an experimental HTTP/3 Server Push transport for `Fetch`, backed by [quic.cr](https://github.com/eltony81/quic.cr). It eliminates polling: jobs are pushed to the worker as soon as they are enqueued.

Build the broker with the compile-time flag and enable HTTP/3 at runtime:

```bash
crystal build -Dmorganite_http3 src/broker.cr -o bin/broker_http3

export MORGANITE_JQCP_HTTP3_ENABLED=true
export MORGANITE_JQCP_HTTP3_PORT=7444
./bin/broker_http3
```

A Crystal worker consumes the push stream with `H3::Client`:

```crystal
require "quic"
require "json"

client = H3::Client.new("127.0.0.1", 7444, QUIC::Config.new)
client.on_push = ->(_push_id : UInt64, _headers : Hash(String, String), body : Bytes) {
  job = JSON.parse(String.new(body))
  puts "Pushed job: #{job["type"]} jid=#{job["jid"]}"
  nil
}

# Open a fetch window; jobs arrive as HTTP/3 Server Push
headers, body, trailers = client.get(
  "/jqcp/v1/worker/fetch?wid=worker-http3-1",
  {"authorization" => "Bearer worker-secret"}
)
```

All other JQCP RPCs (`Hello`, `Ack`, `Fail`, `RenewLease`, `Beat`) remain plain JSON-over-HTTP/1.1. See `examples/jqcp_demo/src/worker_http3.cr` and the bonus section of [`docs/jqcp_tutorial.md`](docs/jqcp_tutorial.md) for a complete, runnable example.

## Docker

A multistage `Dockerfile` is provided in the repository root.

```bash
make docker-build
```

Run the image:

```bash
docker run --rm -e MORGANITE_REDIS_URL=redis://host.docker.internal:6379/0 -p 7420:7420 morganite:latest
```

## Releases

Tagging a commit `vX.Y.Z` and pushing the tag triggers `.github/workflows/release.yml`,
which runs the test suite, cross-compiles a statically-linked `morganite` binary
(Alpine/musl, no runtime dependency on the host's libc), and publishes it as a
GitHub Release with the matching `CHANGELOG.md` section as the release notes.

To build the same static binary locally:

```bash
make build-static
# or: ./scripts/build_static.sh path/to/output
```

## Development

You need Crystal 1.20+ and a local Redis server.

```bash
# Install dependencies
make install

# Run tests
make test

# Format code
make fmt

# Run linter
make lint
```

A `docker-compose.yml` is provided for local Redis:

```bash
docker-compose up -d redis
```

## End-to-end tests

An example application lives in `examples/demo_app/` and is used to validate Morganite-like scenarios against a real Redis.

With Podman (the default for this project):

```bash
./scripts/run_e2e.sh
```

With Docker:

```bash
DOCKER_COMPOSE="docker-compose" ./scripts/run_e2e.sh
```

Or manually:

```bash
podman-compose -f docker-compose.e2e.yml up --build --abort-on-container-exit
```

The `e2e` service enqueues 100 jobs, waits for the `worker` to process them, and exits with code `0` on success.

## Load test

Not part of `make test` or CI — a separate, heavier suite for measuring throughput and latency against a real (separate-process) worker.

```bash
./scripts/run_load_test.sh

# Override job count / timeout:
JOB_COUNT=50000 TIMEOUT_SECONDS=300 ./scripts/run_load_test.sh
```

The `load` service enqueues `JOB_COUNT` jobs (default 20,000), waits for the `worker` service to drain them, and reports throughput (jobs/sec) and average enqueue-to-processed latency. Exits non-zero if any jobs are lost or the queue doesn't fully drain within `TIMEOUT_SECONDS`.

## Stress test

Also not part of CI. Floods the queue with `JOB_COUNT` jobs (default 100,000) across two worker processes, then hard-kills one of them (`SIGKILL`, no graceful shutdown) partway through to prove `OrphanReaper` requeues whatever that process left behind in its `morganite:processing:*` list, and the survivor still fully drains the flood.

```bash
./scripts/run_stress_test.sh

# Override job count / timeout:
JOB_COUNT=200000 TIMEOUT_SECONDS=600 ./scripts/run_stress_test.sh
```

## Benchmark against Sidekiq

Also not part of CI. Runs the same job shape (a no-op job that records completion count and enqueue-to-processed latency via its own dedicated connection pool, `incr` + `incrbyfloat` per job) through Morganite and through [Sidekiq](https://sidekiq.org/) (`examples/benchmark/sidekiq/`) sequentially against a fresh Redis each, then prints throughput/latency for both.

```bash
./scripts/run_benchmark.sh

# Override job count / concurrency / timeout:
JOB_COUNT=100000 CONCURRENCY=20 TIMEOUT_SECONDS=300 ./scripts/run_benchmark.sh
```

The Morganite side builds with `crystal build --release` (`examples/demo_app/Dockerfile.release`) rather than `crystal run` (used by the e2e/load/stress suites for faster iteration) — `crystal run` skips LLVM optimizations, which would be a large, unfair handicap against Ruby (no such debug/release distinction to begin with).

## License

MIT. See [LICENSE](./LICENSE).
