# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project

Morganite is a Redis-backed background job processing library for Crystal, inspired by Sidekiq. Requires Crystal 1.20+ (see `shard.yml`) and a local Redis server.

## Commands

```bash
make install    # shards install
make test       # crystal spec (requires Redis; spec_helper uses redis://localhost:6379/15 by default)
make fmt         # crystal tool format
make fmt-check   # crystal tool format --check
make lint        # crystal run bin/ameba.cr
make build       # crystal build src/morganite/cli_main.cr -o bin/morganite --release
make docker-build
make clean
```

Run a single spec file: `crystal spec spec/morganite/worker_spec.cr`. Run a single example: `crystal spec spec/morganite/worker_spec.cr:42` (line number of the `it` block).

Point tests at a different Redis with `MORGANITE_REDIS_URL` (CI uses `redis://redis:6379/15`). `spec_helper.cr` flushes DB 15 before/after every example — never point it at a DB with real data.

End-to-end tests live in `examples/demo_app/` and run against a real Redis via `docker-compose.e2e.yml`:

```bash
./scripts/run_e2e.sh                                    # Podman (default)
DOCKER_COMPOSE="docker-compose" ./scripts/run_e2e.sh     # Docker
```

CI (`.github/workflows/ci.yml`) runs `crystal tool format --check`, `./lib/ameba/bin/ameba`, and `crystal spec` against a service-container Redis. Always run fmt-check and lint before considering a change done, since CI treats both as blocking.

## Architecture

### Module load order matters

`src/morganite.cr` requires every submodule in a specific order (job/registry before worker/client, middleware before processor, etc.) and exposes `Morganite.start` / `.stop` / `.wait` plus the global `Morganite.config`/`Morganite.pool`. New submodules should be required here, respecting dependency order, and everything hangs off the top-level `Morganite` module rather than being independently `require`-able.

### Runtime pipeline (`Launcher`)

`Launcher#run` (`src/morganite/launcher.cr`) is the heart of the running process. It spawns, as fibers:
- `fetch_loop` — reliable fetch via `BRPOPLPUSH morganite:queue:<name> -> morganite:processing:<hostname>:<pid>`, feeding a bounded `Channel(String)`.
- `@concurrency` × `worker_loop` — each owns one pooled Redis client and a `Processor`, pulling jobs off that channel and removing them from the processing list (`LREM`) once handled, success or failure.
- `RetryPoller`, `ScheduledPoller`, `CronScheduler` — independent poll loops (1s ticks) that move mature jobs from `morganite:retry` / `morganite:scheduled` sorted sets (score = Unix timestamp) back into queue lists via `PollerScript` (Lua, for atomicity).
- `Morganite::Web` (Kemal) — optional embedded dashboard, started/stopped alongside the rest unless `--web-only` or `start_web: false`.

Shutdown is cooperative: `Launcher#stop` closes a shutdown channel; `fetch_loop` stops pulling, in-flight jobs drain, then pollers/web stop and `Hooks` fire (`on_startup`/`before_first_fetch`/`after_last_fetch`/`on_shutdown`, `src/morganite/hooks.cr`).

### Worker definition and dispatch

`include Morganite::Worker` (`src/morganite/worker.cr`) self-registers the class in `WorkerRegistry` (name → factory proc) at compile time via the `included` macro — this is why worker classes **must be required before `Morganite.start` is called** in a consuming app's binary. Class-level DSL: `sidekiq_options`, `unique`, `rate_limit`, `cron`, `server_middleware`. `perform_async`/`perform_at`/`perform_in` all funnel through `Morganite::Client`.

`Processor#process` (`src/morganite/processor.cr`) is the per-job execution path: acquire `while_executing` unique lock → check rate limit (reschedule if exceeded) → run through server middleware chain → `worker.perform(args)` → on success, release `until_executed` lock / notify batch / notify workflow; on failure, hand off to `Failures.handle`, which increments retry_count and either re-schedules (`morganite:retry` ZSET, exponential backoff via `Retry.backoff_for`) or moves the job to `morganite:dead`.

### Redis key schema

See `docs/redis_schema.md` for the authoritative list. Everything is prefixed `morganite:`; queues/scheduled/retry/dead are lists or sorted sets of job JSON, unique locks are `SET NX EX` strings, batches/workflows are hashes. `Job` (`src/morganite/job.cr`) is the sole wire format — `JSON::Serializable`, round-tripped as-is through every structure.

### Cross-cutting features built on the same primitives

- **Unique jobs** (`unique_jobs.cr`): lock key = SHA256 of `class|queue|args`. `while_executing` locks only around execution (`Processor`); `until_executed`/`until_expired` lock at enqueue time via a Lua script in `Client` (`UNIQUE_ENQUEUE_SCRIPT`) so the lock-and-push is atomic.
- **Batches** (`batch.cr`) / **Workflows** (`workflow.cr`): metadata hashes keyed by bid/wid; `Processor` notifies them on job success/failure via `job.bid`/`job.wid` set at enqueue time.
- **Rate limiting** (`rate_limiter.cr`): sliding window per worker class; `Processor` reschedules (re-enqueues) jobs that exceed the limit rather than failing them.
- **Middleware**: two independent chains — `ServerMiddleware` (wraps job execution, `src/morganite/server_middleware.cr` + `middleware/*_middleware.cr`) and `ClientMiddleware` (wraps enqueue, `client_middleware.cr`). Built-in middlewares (logging, metrics, Datadog, tracing) are opt-in, not auto-registered.
- **JQCP** (`src/morganite/jqcp/*`): semantic conformance layer for a gRPC-based job-queue control protocol, exposed as JSON-over-HTTP under `/jqcp/v1/` on the same Kemal server as the dashboard (mounted from `web.cr`) — see `docs/jqcp_conformance.md` for the full rationale (no viable Crystal gRPC-streaming stack) and endpoint reference. Reuses the core Redis structures directly (a JQCP-claimed job is a job in `morganite:processing:<wid>`, same scheme as a native fiber worker's `<hostname>:<pid>`, so `OrphanReaper` covers a dead JQCP worker for free); `Jqcp::LeaseReaper` adds the one genuinely new mechanism, per-job Lease timeout independent of process health.

### Configuration

`Morganite::Configuration` (`configuration.cr`) is constructed from `ENV` by default; `Configuration.from_file` loads YAML/JSON and env vars still take precedence unless overridden by CLI flags. Assigning `Morganite.config = ...` calls `validate!` and reconfigures `Logger` as a side effect — don't construct configs and forget to assign them through the setter, direct mutation of `Morganite.config` (a `class_getter`) skips validation/logger sync only if you bypass the `config=` setter entirely (e.g. mutating an in-place `Configuration` object obtained from the getter still needs a re-assign to trigger validation).

### CLI and standalone binaries

Because Crystal is compiled, consuming apps need their own entrypoint that `require`s Morganite plus their worker files, then either calls `Morganite.start; Morganite.wait` directly or `require`s `morganite/cli` and calls `Morganite::CLI.run` for full flag support (see README "Running the processor"). `src/morganite/cli.cr` defines the `CLI` class (`--config`, `--concurrency`, `--queue`, `--verbose`, `--web-only`, `--inline 'Worker [args]'`, `--version`) but does **not** self-invoke — it used to via a `PROGRAM_NAME`-matching guard, which was removed because it fired on `require` alone whenever the binary happened to be named exactly `morganite`, before any later-required worker files got a chance to register (a real footgun given this project's own Docker/docs examples produce exactly that binary name). `src/morganite/cli_main.cr` (`require "./cli"; Morganite::CLI.run`) is the shard's own `bin/morganite` entrypoint and the pattern every consuming app's own entrypoint should follow — always call `CLI.run` explicitly, never rely on auto-invocation.

## Testing conventions

- `spec/spec_helper.cr` flushes Redis DB 15 before and after every example, and clears `ClientMiddleware`/`ServerMiddleware` registrations — specs that register middleware or workers should not assume state from other specs.
- Tests exercise real Redis (via `Morganite.pool`/`RedisConnection.new_client`), not mocks.
- `examples/demo_app/` is a full example application (with its own `lib/` shards) used only for e2e — not part of the main shard's test suite.
