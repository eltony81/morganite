# Changelog

All notable changes to Morganite are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.2.1] - Unreleased

Two more fixes found by re-running the load/stress/e2e suites against 0.2.0, plus the one deferred item from the original `issues.md` pass.

### Fixed

- **`RateLimiter.reschedule`** pushed a rate-limited job straight back onto the queue (`LPUSH`), so a worker could pull it right back off before the window reset and busy-loop until it finally did — burning CPU/Redis calls and producing a disproportionate amount of log output (verified: the same e2e scenario dropped from ~212,000 log lines to 616). Now delays the job onto `morganite:scheduled` until the window is likely to have reset, reusing the existing `ScheduledPoller` machinery instead of a new delay mechanism.
- **O(N) job-by-jid lookups** (`Failures.find_by_jid`, `web.cr#find_job`) scanned the entire retry/dead/scheduled sorted set on every retry/delete/dashboard-detail lookup. Added `Morganite::JobIndex` (`morganite:job_index`), a `jid -> {location, job}` hash verified via `ZSCORE` before being trusted (never a false positive) with the original O(N) scan kept as a fallback on a miss.

## [0.2.0] - 2026-07-18

A correctness/reliability/security pass across the whole runtime pipeline, driven by real end-to-end, concurrency, load and stress testing rather than inspection alone. See `issues.md` for the full bug writeups.

### Fixed

- **Rate limiter** allowed only 1 job per window regardless of the configured `limit` (`DECR` on a never-seeded Redis key).
- **Batch** completion callbacks could fire more than once, or fire prematurely while a batch was still being built: `pending` is now bumped before enqueueing (not after), and a new `Batch#finish` (auto-called by `Batch.open`) gates completion on construction actually being done.
- **Batch** completion could self-deadlock the whole worker pool: `Client.enqueue` for a callback job was called while still holding the connection pool slot used to update counters, exhausting the pool at steady-state concurrency.
- **Launcher** capped the entire pipeline's throughput at 1 fetch/second regardless of `concurrency`, and its shutdown signal could be silently dropped by a race between two independent receivers on the same channel — occasionally losing a job mid-shutdown. Shutdown now uses `Channel#close` (broadcasts to all waiters) instead of a single `send`.
- **`UniqueJobs.unlock`** was an unconditional `DEL`; a slow job whose lock TTL had already expired could delete a different job instance's active lock. Now compare-and-delete via a Lua script.
- Worker fibers and poller fibers (`RetryPoller`, `ScheduledPoller`, `CronScheduler`) could be permanently killed by a malformed job payload, an unregistered worker class, or a single Redis error — silently shrinking effective concurrency or stopping retries/schedules/cron forever. Both are now hardened to log and continue.
- Web dashboard: "Retry"/"Delete" actions were wired to the wrong Redis key for Scheduled/Retry jobs and were silent no-ops; job data was interpolated into HTML unescaped (stored/reflected XSS); Basic Auth and CSRF comparisons weren't constant-time.
- `CronExpression#next` could scan its full ~10-year search horizon on every poll, forever, for an unsatisfiable day-of-month/month combination (e.g. February 31st) — now rejected at registration.
- `Metrics` histograms stored every raw observed value forever; now bucketed counters (Prometheus-style), bounded memory regardless of job volume.
- `web.cr` used the blocking `KEYS` command instead of `SCAN` for dashboard key enumeration.

### Added

- `OrphanReaper`: requeues jobs left behind in a `morganite:processing:*` list by a process that died without a graceful shutdown (crash, `SIGKILL`, OOM), based on a per-process heartbeat key.
- `MORGANITE_ORPHAN_REAPER_POLL_INTERVAL_SECONDS` configuration option.
- Structured logging across the previously-silent parts of the pipeline: Redis connection-pool wait time, launcher shutdown phases, unique-lock acquisition, batch/workflow completion, retry/dead-letter transitions, poller cycles, and web auth/CSRF failures.
- `spec/morganite/concurrency_spec.cr`: multi-fiber reliable-fetch correctness, concurrent unique-enqueue races, concurrent rate-limiter races.
- Non-happy-path spec coverage: malformed job payloads, unregistered worker classes, `Discard`, denied unique locks, poller resilience to Redis errors.
- Load test (`scripts/run_load_test.sh`, opt-in, not part of CI): throughput/latency measurement against a real separate-process worker.
- Stress test (`scripts/run_stress_test.sh`, opt-in, not part of CI): floods the queue and hard-kills a worker process mid-flight to exercise `OrphanReaper` recovery.
- E2E suite (`scripts/run_e2e.sh`) extended to verify the rate limiter, batch, and cron fixes directly, not just baseline job processing.

## [0.1.0] - 2026-07-18

### Added

- Core queue engine: enqueue/dequeue with Redis lists and atomic `brpoplpush` reliable fetch.
- Job model with JSON serialization, JID generation, and execution metadata.
- Worker DSL (`include Morganite::Worker`) with `perform_async`, `perform_at`, `perform_in`, and `cron` macros.
- Retry engine with exponential backoff, jitter, and dead-letter queue.
- Scheduled job poller and cron scheduler.
- Web UI (Kemal) with dashboard, queue views, dead/retry/scheduled management, and basic auth.
- `/health` and `/metrics` (Prometheus) endpoints.
- Server and client middleware hooks.
- Unique jobs with `while_executing`, `until_executed`, and `until_expired` strategies.
- Batches (M7.2) with success/complete callbacks.
- Rate limiting (M7.3) per worker with Redis sliding window.
- Workflows (M7.4) for chained jobs.
- CLI with `--config`, `--concurrency`, `--queue`, `--require`, `--verbose`, `--web-only`, `--inline`, `--version`, and `--help`.
- Configuration from YAML/JSON files with environment-variable override.
- Dockerfile multistage and `make docker-build` target.

[0.2.1]: https://github.com/eltony81/morganite/releases/tag/v0.2.1
[0.2.0]: https://github.com/eltony81/morganite/releases/tag/v0.2.0
[0.1.0]: https://github.com/eltony81/morganite/releases/tag/v0.1.0
