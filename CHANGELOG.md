# Changelog

All notable changes to Morganite are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.2.4] - 2026-07-19

### Added

- Semantic conformance layer for JQCP (`draft-difluri-jqcp-02`, a gRPC-based job-queue control protocol): the full `JobWorker` (Hello/Enqueue/Fetch/Ack/Fail/RenewLease/Beat) and `JobOperator` (ListQueues/GetQueue/UpdateQueue/GetJob/RetryJob/KillJob/DeleteJob/ListJobs/ListWorkers/GetStats) services, exposed as JSON-over-HTTP under `/jqcp/v1/` (real gRPC transport isn't feasible in Crystal today — see `docs/jqcp_conformance.md`). New `Job` fields (`priority`, `timeout_seconds`, `idempotency_key`, `error_type`, `max_lease_seconds`); `Jqcp::QueueControl` (pause + strict/weighted priority strategy, also now used by `Launcher`'s own queue selection); `Jqcp::LeaseReaper` (per-job Lease timeout, independent of `OrphanReaper`'s coarser process-level recovery); Bearer-token scoped auth (`jqcp:worker`, `jqcp:operator:read`, `jqcp:operator:write`).
- `spec/morganite/jqcp/e2e_scenarios_spec.cr`: the protocol author's own end-to-end scenario catalogue (smoke test, read-only queries, happy path, transient-failure retry, retry exhaustion/dead-lettering, worker-crash Lease recovery, poison-pill kill, idempotency-key dedup, RenewLease) implemented and run against real Redis. Found and fixed a real gap in the process: `scheduledAt` (Table 1) was never rendered in Job JSON responses at all — `Jqcp.scheduled_at_for`/`ListJobs`' bulk `ZRANGE ... WITHSCORES` now supply it.
- **Experimental HTTP/3 Fetch transport**, using [quic.cr](https://github.com/eltony81/quic.cr) `~> 0.11.0` as a real dependency for genuine HTTP/3 Server Push (RFC 9114 §4.6) instead of bounded polling — closer to real JQCP streaming semantics for the one RPC (`Fetch`) that benefits from it. Opt-in and off by default (`MORGANITE_JQCP_HTTP3_ENABLED`); every other RPC (Hello/Enqueue/Ack/Fail/RenewLease/Beat, the whole Management API) deliberately stays on the existing JSON-over-HTTP surface. See `docs/jqcp_conformance.md`'s new "HTTP/3 Fetch (experimental)" section for the enable-flags, the window/reconnect model, and the interop caveat (only a quic.cr-based client can consume it). Verified with a real end-to-end run: jobs enqueued via JSON-HTTP while an HTTP/3 Fetch window is open arrive as separate pushes in real time over real UDP.
- **`RenewLease` RPC** (`draft-difluri-jqcp-02` Section 7.6/8.4, superseding `-01`): lets a Worker extend a single Job's Lease — via `POST /jqcp/v1/worker/renew_lease` — without releasing it, independent of `Beat` (which only refreshes Worker-session liveness, never an individual Job's Lease). New `Job#max_lease_seconds` field (0/absent = no cap) bounds cumulative ACTIVE time across any number of renewals; a renewal that would exceed the cap is not extended — the Broker kills the Job the same way an Operator's `KillJob` would and responds `{"killed":true}` rather than rejecting the call. A Job killed while a Worker still believes it holds the Lease is remembered for a short grace window so that Worker's next `RenewLease` call learns of the kill (`killed:true`) instead of only discovering it via a rejected Ack/Fail. See `docs/jqcp_conformance.md`'s new "RenewLease" section for the full state-transition table. Also brought the rest of `docs/jqcp_conformance.md` and its Section-number cross-references up to `-02` (`RenewLease` inserted between Fail and Beat shifted Beat 7.6→7.7, Worker Session Lifecycle 7.7→7.8, and RetryJob/KillJob/DeleteJob/Activation-Time-Reached/Lease-Timeout-Expired 8.4-8.8→8.5-8.9).

### Fixed

- **`cli.cr`'s top-level auto-invoke guard could fire before a consuming app's worker files were even required.** It matched on `File.basename(PROGRAM_NAME) == "morganite"` (fixed in 0.2.3), but `require "morganite/cli"` positioned before other worker `require`s — exactly the order this project's own `docs/usage.md` recommended — combined with a binary literally named `morganite` (also produced by this project's own recommended Docker pattern) fired the guard at the `require` line itself, before any later class got a chance to register. Removed the guard entirely: `cli.cr` now only defines `Morganite::CLI`, never self-invokes. The shard's own `bin/morganite` target is now `src/morganite/cli_main.cr` (`require "./cli"; Morganite::CLI.run`), the same explicit-call pattern every consuming app should use.

## [0.2.3] - 2026-07-18

### Fixed

- **The compiled `morganite` binary's CLI never actually ran** for any normal invocation (`./bin/morganite`, an absolute path, the static release binary) — only the literal argv[0] `"morganite"` with no path prefix (e.g. Docker's `ENTRYPOINT ["morganite"]`) happened to work. Found by actually running the `v0.2.2` static release binary end-to-end: `--version`/`--help` silently produced no output and exited 0. Root cause: `PROGRAM_NAME` is `argv[0]` verbatim, not a basename, so `PROGRAM_NAME == "morganite"` doesn't match `./bin/morganite`, and the `PROGRAM_NAME.ends_with?("/cli.cr")` fallback (meant for `crystal run`) was dead code — `crystal run`/`crystal spec` both use a temp compiled binary path, never the source filename. Fixed with `File.basename(PROGRAM_NAME) == "morganite"`.

## [0.2.2] - 2026-07-18

CI/release tooling and docs cleanup — no runtime behavior changes.

### Fixed

- **CI** was failing on every push since Crystal 1.21.0's release (new lexer support for `%W`): `ameba` 1.6.4, its latest stable release, doesn't build against it. `ci.yml` and the new `release.yml` are pinned to `crystallang/crystal:1.20` until ameba ships 1.21 support; `shard.yml`'s declared minimum matches (`1.20.2`).

### Added

- `.github/workflows/release.yml`: tagging `vX.Y.Z` runs the test suite, cross-compiles a statically-linked release binary (Alpine/musl), and publishes a GitHub Release with the matching `CHANGELOG.md` section as its notes.
- `scripts/build_static.sh` / `make build-static`: builds the same static binary locally.

### Removed

- The "early development, APIs will change" status note from `README.md`/`CLAUDE.md` — no longer an accurate description of the project's maturity.

## [0.2.1] - 2026-07-18

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
