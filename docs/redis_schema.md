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
| `morganite:scheduled` | Sorted set | Jobs scheduled for future execution. Score = Unix timestamp. |
| `morganite:retry` | Sorted set | Jobs waiting to be retried. Score = next retry Unix timestamp. |
| `morganite:dead` | Sorted set | Jobs that exhausted all retries. Score = time the job became dead. |

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

## Notes

- All keys use the `morganite:` prefix to avoid collisions.
- Queue names are sanitized by the application; Redis key names are not escaped beyond the prefix.
- Job payloads are stored as JSON strings inside lists and sorted sets.
