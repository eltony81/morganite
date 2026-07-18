# Changelog

All notable changes to Morganite are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.1.0] - Unreleased

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

[0.1.0]: https://github.com/eltony81/morganite/releases/tag/v0.1.0
