# Morganite

[![CI](https://github.com/eltony81/morganite/actions/workflows/ci.yml/badge.svg)](https://github.com/eltony81/morganite/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)

Morganite is a background job processing library for [Crystal](https://crystal-lang.org/), inspired by [Sidekiq](https://sidekiq.org/).

It uses **Redis** as a backend and aims to provide a Ruby-like developer experience while leveraging Crystal’s compiled, fiber-based concurrency.

> **Status**: early development. APIs will change.

## Features (planned)

- Worker-based job processing
- Redis-backed queues
- Retries with exponential backoff
- Scheduled jobs
- Dead-letter queue
- Built-in Web UI (Kemal)
- Middleware and lifecycle hooks
- Monitoring and health checks

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
MyWorker.perform_async(["hello", "world"])
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
