# Morganite Redis schema

Morganite uses Redis as its sole backend. This document describes the keys, lists, sorted sets, and hashes used by the system.

## Queues

| Key | Type | Description |
|-----|------|-------------|
| `morganite:queue:<name>` | List | Jobs waiting to be processed on queue `<name>`. |
| `morganite:processing:<hostname>:<pid>` | List | Jobs currently being processed by a specific worker process. Used for reliable fetch (`brpoplpush`). |
| `morganite:processes:<hostname>:<pid>` | String | Heartbeat for a running process, refreshed periodically with `SET ... EX`. Used by `OrphanReaper` to tell a live process from one that died without a graceful shutdown (crash, `SIGKILL`, OOM) and requeue whatever was left in its `morganite:processing:*` list. |

## Scheduling and retries

| Key | Type | Description |
|-----|------|-------------|
| `morganite:scheduled` | Sorted set | Jobs scheduled for future execution. Score = Unix timestamp. Also used to delay a rate-limited job until its window is likely to have reset, instead of pushing it straight back onto the queue. |
| `morganite:retry` | Sorted set | Jobs waiting to be retried. Score = next retry Unix timestamp. |
| `morganite:dead` | Sorted set | Jobs that exhausted all retries. Score = time the job became dead. |
| `morganite:job_index` | Hash | Secondary index (`jid -> {location, job JSON}`) for O(1)/O(log N) job-by-jid lookups against the three sets above, instead of an O(N) `ZRANGE` + scan. A hint, not a source of truth: entries can go stale and are verified (`ZSCORE`) before being trusted; lookups fall back to the O(N) scan on a miss. See `Morganite::JobIndex`. |

## Unique jobs

| Key | Type | Description |
|-----|------|-------------|
| `morganite:unique:<digest>` | String | Lock key for unique jobs. Set with `NX`/`EX`. |

## Batches

| Key | Type | Description |
|-----|------|-------------|
| `morganite:batch:<bid>` | Hash | Batch metadata: `description`, `total`, `pending`, `success`, `fail`, `success_callback`, `complete_callback`. |

## Workflows

| Key | Type | Description |
|-----|------|-------------|
| `morganite:workflow:<wid>` | Hash | Workflow metadata. Currently stores the `steps` key as a JSON array of step definitions. |

## JQCP

Semantic conformance layer for JQCP (`draft-difluri-jqcp-02`) — see `docs/jqcp_conformance.md`. Reuses every key above unchanged (a JQCP-claimed job is a job in `morganite:queue:*`/`morganite:processing:*`/etc. exactly like any other); the keys below are the only genuinely new state.

| Key | Type | Description |
|-----|------|-------------|
| `morganite:processing:<wid>` / `morganite:processes:<wid>` | List / String | A JQCP Worker's claimed jobs and heartbeat, sharing the exact same key scheme as a native fiber worker's `<hostname>:<pid>` (see "Queues" above) — `OrphanReaper` recovers a dead JQCP worker's in-flight jobs with no JQCP-specific code. |
| `morganite:jqcp:session:<wid>` | String (JSON) | Worker Session Lifecycle record (Section 7.8): `state`, `queues`, `concurrency`, `last_beat`. TTL'd and refreshed by Hello/Beat; expires along with the heartbeat above. |
| `morganite:jqcp:leases` | Sorted set | Per-job Lease expiry (Section 8.9), score = Unix timestamp, member = job JSON. Only populated for jobs fetched with `timeout_seconds > 0`; polled by `LeaseReaper`. `RenewLease` (Section 7.6) re-scores the same member in place rather than releasing it. |
| `morganite:jqcp:leased_at:<wid>:<jid>` | String | Set once, at the original Fetch, only for `max_lease_seconds > 0` jobs — the timestamp `RenewLease` (Section 8.4) compares against to compute cumulative ACTIVE time against the cap. TTL'd well past `max_lease_seconds`; cleared on Ack/Fail. |
| `morganite:jqcp:recently_killed:<wid>:<jid>` | String | Short-lived (30s) courtesy marker set whenever a Job is killed while still under a Lease (KillJob or the `max_lease_seconds` cap) — lets that Job's next `RenewLease` call return `killed:true` instead of `job_not_found` (Section 7.6/8.4). |
| `morganite:jqcp:idem:<queue>:<key>` | String | Idempotency-key reservation (Section 4.4), value = holding job's `jid`. Set with `NX`; released (compare-and-delete) once the job leaves a non-terminal state. |
| `morganite:queue:<name>:paused` | String | Presence = queue is paused (Section 9.3). Checked by `Launcher#fetch_one` and the JQCP Fetch handler alike — not JQCP-exclusive, just introduced by it. |
| `morganite:jqcp:priority_strategy` | String (JSON) | Broker-default priority strategy (Section 10): `mode` (`strict`/`weighted`) and per-queue `weights`. |

## Notes

- All keys use the `morganite:` prefix to avoid collisions.
- Queue names are sanitized by the application; Redis key names are not escaped beyond the prefix.
- Job payloads are stored as JSON strings inside lists and sorted sets.
