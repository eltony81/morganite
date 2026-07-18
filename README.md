# Morganite

[![CI](https://github.com/eltony81/morganite/actions/workflows/ci.yml/badge.svg)](https://github.com/eltony81/morganite/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)

Morganite is a background job processing library for [Crystal](https://crystal-lang.org/), inspired by [Sidekiq](https://sidekiq.org/).

It uses **Redis** as a backend and provides a Ruby-like developer experience while leveraging Crystal’s compiled, fiber-based concurrency. Morganite is designed for production use with built-in observability, reliability patterns and a lightweight embedded dashboard.

> **Status**: early development. APIs will change.

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

```crystal
require "morganite"

class MyWorker
  include Morganite::Worker

  def perform(args)
    puts "Processing #{args}"
  end
end

# Enqueue a job
MyWorker.perform_async("hello", "world")
```

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

## Docker

A multistage `Dockerfile` is provided in the repository root.

```bash
make docker-build
```

Run the image:

```bash
docker run --rm -e MORGANITE_REDIS_URL=redis://host.docker.internal:6379/0 -p 7420:7420 morganite:latest
```

## Development

You need Crystal 1.15+ and a local Redis server.

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

## License

MIT. See [LICENSE](./LICENSE).
