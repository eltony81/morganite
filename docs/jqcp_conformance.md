# JQCP conformance

Morganite implements a **semantic conformance layer** for the Job Queue
Control Protocol (JQCP), `draft-difluri-jqcp-02`. This document states
precisely what that means, what's implemented, what's deliberately not, and
why — so a reader with the actual Internet-Draft in hand can check this
implementation against it section by section.

`draft-difluri-jqcp-01` supersedes an earlier `-00` revision (an HTTP/JSON
REST design); `-01` rewrote the transport onto gRPC + Protocol Buffers while
keeping the same data model and job/session state machines. `-02` supersedes
`-01`, adding the `RenewLease` RPC and `max_lease_seconds` (Section 7.6/8.4)
without otherwise changing the data model or state machines — every
`-01`-era section reference elsewhere in this document that doesn't
explicitly say `-02` still applies unchanged (only the RenewLease-adjacent
sections were renumbered, `8.4`-`8.8` → `8.5`-`8.9`, see below). `-02` is the
draft this document tracks.

## Why JSON-over-HTTP, not gRPC

JQCP's normative transport is gRPC over HTTP/2 with binary Protocol Buffers
encoding (Section 5.2), and its core Worker-loop RPC, `Fetch`, is defined as
*mandatory server-streaming*. As of this writing, Crystal has no viable gRPC
stack for that: the only existing shard (`jgaskins/grpc`) explicitly
documents that it supports unary calls only — no streaming, no TLS. Getting
real wire-level gRPC conformance would mean building gRPC-over-HTTP/2 framing
(length-prefixed protobuf frames, trailers-based status codes, streaming call
lifecycle) essentially from scratch on top of a raw HTTP/2 shard — a
multi-week, high-risk undertaking unrelated to Morganite's actual job
semantics.

Section 5.2 itself anticipates this gap:

> implementations MAY additionally expose this JSON mapping (e.g. via a
> grpc-gateway-style transcoding proxy) but are not REQUIRED to.

Morganite takes that path: every RPC in Appendix C's `JobWorker` and
`JobOperator` services is implemented with the *exact* state-machine and
per-(RPC, state) behavior specified in Section 8, exposed as JSON-over-HTTP
under `/jqcp/v1/` on the existing embedded Kemal server (same process/port as
the dashboard, `/health`, `/metrics`). A client speaking real gRPC cannot
talk to this Broker; a client speaking JSON-over-HTTP against the endpoints
below gets byte-for-byte the same job lifecycle behavior the spec describes.

## Endpoints

All requests/responses are JSON bodies (`Content-Type: application/json`),
field names in `camelCase` matching Appendix C's proto3-canonical-JSON
examples. Every RPC below requires a `Authorization: Bearer <token>` header;
see [Authentication](#authentication).

### Worker API (`JobWorker`, Section 7) — scope `jqcp:worker`

| RPC | Endpoint | Notes |
|-----|----------|-------|
| Hello | `POST /jqcp/v1/worker/hello` | `{"wid","queues","concurrency"}` → `{"priorityStrategy","recommendedBeatIntervalSeconds"}` |
| Enqueue | `POST /jqcp/v1/worker/enqueue` | `{"job":{...}}` → the full Job (Table 1 shape). A future `scheduledAt` routes through the same scheduling path as `perform_at`/`perform_in` — JQCP has no separate "ScheduleJob" RPC. |
| Fetch | `POST /jqcp/v1/worker/fetch` | `{"wid"}` → a Job (200) or empty body (204) if nothing became eligible within `MORGANITE_JQCP_FETCH_TIMEOUT_SECONDS` (default 5s). **Not streaming** — see [Fetch](#fetch-non-streaming-fallback) below. |
| RenewLease | `POST /jqcp/v1/worker/renew_lease` | `{"wid","jid"}` → `{"killed"}` (`draft-difluri-jqcp-02` Section 7.6, see [RenewLease](#renewlease) below) |
| Ack | `POST /jqcp/v1/worker/ack` | `{"wid","jid"}` → `{}` |
| Fail | `POST /jqcp/v1/worker/fail` | `{"wid","jid","errtype","message","backtrace"}` → `{}` |
| Beat | `POST /jqcp/v1/worker/beat` | `{"wid"}` → `{"signal":"RUN_SIGNAL_RUN"}` |

### Management API (`JobOperator`, Section 9) — scope `jqcp:operator:read`/`jqcp:operator:write`

| RPC | Endpoint | Scope | Notes |
|-----|----------|-------|-------|
| ListQueues | `GET /jqcp/v1/operator/list_queues` | read | |
| GetQueue | `POST /jqcp/v1/operator/get_queue` | read | Never 404s — queues aren't pre-declared in Morganite, they exist implicitly on first Enqueue. |
| UpdateQueue | `POST /jqcp/v1/operator/update_queue` | write | `updateMask` is a comma-separated list of `paused`/`priorityStrategy`. |
| GetJob | `POST /jqcp/v1/operator/get_job` | read | Searches all six states (see [State mapping](#state-mapping)). |
| RetryJob | `POST /jqcp/v1/operator/retry_job` | write | `resetCount` defaults to `true` (Section 8.5). |
| KillJob | `POST /jqcp/v1/operator/kill_job` | write | Idempotent on an already-dead job (Section 8.6). |
| DeleteJob | `POST /jqcp/v1/operator/delete_job` | write | Requires `"confirm":true`; only valid from `dead`. |
| ListJobs | `POST /jqcp/v1/operator/list_jobs` | read | `states`, `pageSize`, `pageToken` (offset-encoded). |
| ListWorkers | `GET /jqcp/v1/operator/list_workers` | read | |
| GetStats | `GET /jqcp/v1/operator/get_stats` | read | `processed`/`failed`/`dead` cumulative counters (existing `Morganite::Metrics`). |

`Watch` (Section 12) is not implemented — see [Out of scope](#out-of-scope).

### Fetch (non-streaming fallback)

Real JQCP `Fetch` is server-streaming: the Broker pushes each eligible Job
onto an open stream the instant it's available. Without a gRPC transport,
this Broker implements Fetch as a single bounded-blocking `BRPOPLPUSH` cycle
per call — mirroring exactly the behavior JQCP's own Appendix A cites as
Faktory's pre-gRPC precedent ("FETCH command, polled, blocks up to 2s"). A
client calls Fetch in a loop; each call blocks up to
`jqcp_fetch_timeout_seconds` and returns either a claimed Job or an empty
204. This is a transport difference only — every Section 8.1 eligibility
rule (activation time, Lease capacity, paused queues) is enforced exactly as
specified; the only thing lost relative to real streaming is Jobs arriving
mid-wait costing up to one poll interval of latency instead of zero.

### HTTP/3 Fetch (experimental)

The bounded-polling fallback above is the default and the only Fetch
transport most deployments need. As an additional, opt-in transport,
Morganite can instead serve Fetch over real HTTP/3 Server Push (RFC 9114
§4.6), using [quic.cr](https://github.com/eltony81/quic.cr) — a pure-Crystal
QUIC/HTTP3 implementation — as a real dependency. This gets closer to real
JQCP streaming semantics: eligible Jobs are pushed to the worker the instant
they're claimed, instead of the worker paying up to one poll interval of
latency.

**Enabling it** — five env vars (or the equivalent `Configuration` fields /
YAML keys), all off by default:

| Env var | Default | Purpose |
| --- | --- | --- |
| `MORGANITE_JQCP_HTTP3_ENABLED` | `false` | Turns the HTTP/3 listener on |
| `MORGANITE_JQCP_HTTP3_PORT` | `7444` | UDP port for the HTTP/3 listener |
| `MORGANITE_JQCP_HTTP3_CERT_FILE` | `cert.pem` | TLS cert (self-signed, auto-generated if missing — same behavior as quic.cr's own examples) |
| `MORGANITE_JQCP_HTTP3_KEY_FILE` | `key.pem` | TLS key, paired with the cert above |
| `MORGANITE_JQCP_HTTP3_FETCH_WINDOW_SECONDS` | `3` | How long one push "window" (see below) stays open |

**Model**: a worker still calls JSON-HTTP `Hello` first to register its
session — HTTP/3 Fetch only replaces the *Fetch* RPC, not session setup or
`Ack`/`Fail`/`Beat`, which stay on JSON-HTTP unchanged. It then opens
`GET /jqcp/v1/worker/fetch?wid=...` on the HTTP/3 listener. That request
stays open for `jqcp_http3_fetch_window_seconds`; every Job that becomes
eligible during the window is pushed immediately as a separate resource
(same claim/Lease logic as the JSON fallback's `fetch_one`, called
repeatedly instead of once), decodable the same way as a normal Fetch
response body. When the window elapses the original request finally
resolves with `{"windowEnded":true}` and the worker opens a new Fetch
request to keep receiving work. This bounds the server-side fiber lifetime
per request instead of running one forever; reconnecting is cheap (a new
stream on the same QUIC connection, not a new handshake), so a short
default window has no real downside.

One implementation detail worth calling out because it isn't obvious from
the RPC-per-RPC framing above: each push attempt inside the window still
goes through the same bounded-blocking claim loop the JSON fallback uses
(`WorkerApi.fetch_one`), and that loop's own internal budget is capped to
whatever time is actually left in the outer window — not its own default —
specifically so a single idle claim attempt can never block past the
window's own deadline.

**Caveats** (why this stays experimental, not the default):
- Only a quic.cr-based HTTP/3 client can consume this — there is no
  interop story with a gRPC/JQCP client today. This is the same tradeoff
  already accepted for the JSON-HTTP surface (not real gRPC either), just
  on a different transport.
- The TLS cert is self-signed and auto-generated if missing — fine for an
  opt-in experimental feature, not for production without replacing it
  (same production gap already documented for the JSON-HTTP surface's TLS
  termination).
- No independent cross-implementation validation is possible: at the time
  this was built, the reference HTTP/3 stack used to sanity-check quic.cr's
  base protocol conformance (quic-go v0.60.0) has no Server Push API at
  all, so Server Push specifically has only been verified against itself.

### RenewLease

`draft-difluri-jqcp-02` (superseding `-01`) added `RenewLease` (Section
7.6/8.4): a Worker extends a single Job's Lease without releasing it,
independent of `Beat`. This is a real, fully server-streaming-agnostic RPC
— unlike `Fetch`, nothing about it depends on the gRPC-vs-JSON-HTTP
transport question, so it's implemented as a normal request/response route
like Ack/Fail, no experimental flag needed.

`Beat` (Section 7.7) and `RenewLease` are deliberately independent signals,
per Section 8.9's closing paragraph: `Beat` only refreshes the *Worker
session* heartbeat (`WorkerSession::HEARTBEAT_TTL_SECONDS`) — it says
nothing about any individual Job's Lease. A worker that calls `Beat` every
15s but never `RenewLease` on a long-running Job will still lose that Job
to `LeaseReaper` once its `timeout_seconds` elapses, exactly as if `Beat`
had never been called at all (covered by
`spec/morganite/jqcp/e2e_scenarios_spec.cr`'s Scenario 7 "Beat alone"
case). The effective Lease deadline is whichever is later: the original
Fetch time plus `timeout_seconds`, or the most recent successful
`RenewLease` plus `timeout_seconds` — `Jqcp::Lease.renew` is literally
`Jqcp::Lease.track` called again, which re-`ZADD`s the same ZSET member
(the Job's own JSON, unchanged) at a fresh score, in place.

`max_lease_seconds` (Table 1's new field, 0/absent means no cap) bounds
cumulative ACTIVE time across any number of renewals, tracked separately
from the Lease ZSET itself via `Jqcp::Lease.leased_at` (set once, at the
original Fetch, only when `max_lease_seconds > 0`). A `RenewLease` call
that would push cumulative ACTIVE time past the cap is **not** extended —
the Broker kills the Job the same way an Operator's `KillJob` would
(`Failures.kill`) and responds `{"killed":true}` rather than rejecting the
call outright, so the worker's own request always succeeds and the
response itself carries the outcome.

A Job Killed while a worker still believes it holds the Lease (either via
the `max_lease_seconds` cap above, or a concurrent Operator `KillJob`) is
recorded in a short-lived (`Jqcp::Lease::RECENTLY_KILLED_GRACE_SECONDS`,
30s) marker keyed by `(wid, jid)`. The worker's *next* `RenewLease` call for
that Job — even though its Lease is already gone — still responds
`{"killed":true}` rather than `job_not_found`, so the worker learns of the
kill within one renewal interval instead of only discovering it on its
eventual Ack/Fail. Once the grace window passes, the same call correctly
falls back to `job_not_found`, matching the poison-pill consistency already
established for late Ack/Fail after a `KillJob` (Scenario 5).

## Data model mapping

- `Job#priority`, `#timeout_seconds`, `#idempotency_key`, `#error_type`,
  `#max_lease_seconds` are the JQCP fields Morganite's `Job` didn't already
  have (Section 4.2/7.5/7.6). `priority` is stored but does not reorder a
  queue's Redis LIST — Section 8.1 only mandates ordering *across* queues
  (Section 10), not within one. `max_lease_seconds` (0/absent = no cap) is
  only meaningful together with `RenewLease` — see [RenewLease](#renewlease).
- `state` (Section 4.3) is never stored on the Job record. It's computed on
  read from which Redis structure currently holds the job
  (`Morganite::Jqcp.state_for`) — see [State mapping](#state-mapping).
- `retry.max`/`retry.count`/`retry.backoff` are rendered from the existing
  `Retry.max_retries_for`/`Job#retry_count`; `backoff` is always reported as
  `BACKOFF_MODE_EXPONENTIAL` (Morganite's only implemented formula, which
  already matches Section 11's recommended `count^4 + base + jitter` shape).
- `last_error` is rendered from the existing `error_message`/`error_type`/
  `error_backtrace`/`failed_at` fields (only `error_type` is new — added so
  JQCP's `errtype` has a real source instead of reusing the worker class
  name, which would have been wrong).
- A Producer-supplied `jid` (Section 4.1) is honored if present, checked
  against the existing collision-detection the unique-job/idempotency
  machinery already provides; otherwise the existing UUID generator is used
  (already conformant with Section 4.1's charset/length constraints).
- `args` round-tripping through `google.protobuf.Value`'s value model
  (Section 4.4) needs no extra validation: Value's model (null/bool/number/
  string/list/struct) is isomorphic to JSON's, so "valid JSON" already
  implies "round-trips through Value."
- `scheduled_at` (Table 1: "Time before which the job MUST NOT be
  dequeued") isn't a `Job` field either — it's the score of whichever ZSET
  (`morganite:scheduled`/`morganite:retry`) currently holds the job, not
  data carried on the job itself. `Jqcp.scheduled_at_for` (a single
  `ZSCORE`) supplies it for single-job responses (GetJob, Enqueue when
  scheduling); `ListJobs`' bulk listing fetches it via
  `ZRANGE ... WITHSCORES` in the same round trip that fetches the jobs,
  rather than one extra round trip per job.

## State mapping

| JQCP state | Redis location |
|---|---|
| `SCHEDULED` | `morganite:scheduled`, `retry_count == 0` |
| `RETRYING` | `morganite:scheduled` with `retry_count > 0`, or `morganite:retry` (Section 4.3: "retrying is functionally a scheduled sub-state") |
| `ENQUEUED` | `morganite:queue:<name>` |
| `ACTIVE` | `morganite:processing:<owner>` (`owner` = a JQCP `wid`, or `hostname:pid` for a native fiber worker — both are the same Lease concept, see below) |
| `DEAD` | `morganite:dead` |
| `SUCCEEDED` | Not retained (Section 4.3 explicitly allows a Broker to discard immediately, "as Sidekiq does") — a succeeded job simply isn't found by GetJob afterward, indistinguishable from one that never existed. |

**Consequence of not retaining `SUCCEEDED`, found while running the scenarios in
`JQCP-e2e-test-scenarios.md`:** Section 8.6 prescribes `KillJob` on a
`SUCCEEDED` job return `FAILED_PRECONDITION`/`invalid_state_transition`. This
Broker can't distinguish "this jid succeeded" from "this jid never existed" —
both return `job_not_found`. Documented as a known, deliberate deviation
(a direct consequence of the immediate-discard choice above, not a bug),
covered by `spec/morganite/jqcp/e2e_scenarios_spec.cr`.

## Sessions and Leases

A JQCP Worker's `morganite:processing:<wid>` / `morganite:processes:<wid>`
keys deliberately share the exact prefix scheme Morganite's own `Launcher`
uses for native fiber workers (`<hostname>:<pid>`). This means `OrphanReaper`
— which scans `morganite:processing:*` generically and checks for a matching
heartbeat — recovers a crashed JQCP worker's in-flight jobs with no
JQCP-specific code at all.

That only covers *process*-level death. Section 8.9's Lease timeout is
*per-job* and independent of whether the claiming worker is otherwise alive
(one hung job in an otherwise-healthy process): `Jqcp::LeaseReaper` polls a
separate `morganite:jqcp:leases` ZSET, populated only for jobs fetched with
`timeout_seconds > 0`, and requeues an expired one without incrementing
`retry_count`, exactly as Section 8.9 specifies. A Worker can push that
per-job deadline back out — without releasing the Lease — via `RenewLease`;
see [RenewLease](#renewlease).

## Authentication

Section 6 requires TLS 1.2+ for any deployment crossing a trust boundary, and
Bearer token call credentials with at least two scopes. This Broker
implements Bearer token scopes (`jqcp:worker`, `jqcp:operator:read`,
`jqcp:operator:write`) via three independent tokens, unset = that scope's
routes are disabled entirely (fail closed):

| Env var | Scope |
|---|---|
| `MORGANITE_JQCP_WORKER_TOKEN` | `jqcp:worker` |
| `MORGANITE_JQCP_OPERATOR_READ_TOKEN` | `jqcp:operator:read` |
| `MORGANITE_JQCP_OPERATOR_WRITE_TOKEN` | `jqcp:operator:write` (also satisfies a `read` check) |

TLS is **not** terminated inside Morganite — see [Out of scope](#out-of-scope).

## Out of scope

Deliberately not implemented, with rationale:

- **Real gRPC wire transport / binary Protocol Buffers** (Section 5.2). No
  viable Crystal gRPC-streaming/TLS stack exists today; see the transport
  discussion above. Revisit if `jgaskins/grpc` (or a successor) gains
  streaming and TLS support.
- **TLS termination inside Morganite** (Section 6). Recommended deployment:
  a TLS-terminating reverse proxy in front of Morganite's embedded server,
  with Morganite itself listening only on a private/loopback interface —
  Section 6 itself treats "loopback or otherwise mutually trusted... private
  network" as an acceptable exception to requiring TLS at that hop.
- **`Watch` RPC** (Section 12). Explicitly OPTIONAL in the spec itself
  ("its absence does not affect conformance to the rest of this document").
- **Broker-initiated Quiet/Terminate push via a Beat response** (Section
  7.6). The spec says the Broker *MAY* do this, not MUST; without streaming
  Fetch there's no way for the Broker to *observe* a Worker's Fetch loop to
  interrupt in the first place, so only the Worker-driven half (a Worker
  choosing to stop calling Fetch) is meaningful in this transport.
- **Multiple concurrent package versions** (`jqcp.v1`/`jqcp.v2`, Section
  5.1). Not applicable — only one version of the protocol exists.

## Verifying this yourself

The full lifecycle trace from the spec's own Appendix B was run against a
real `Morganite.start` instance (real Redis, real HTTP, no mocks) during
development; every step produced exactly the state transition and response
shape the spec describes: Enqueue → Hello → Fetch (returns the Job as
`ACTIVE`) → Fail (→ `RETRYING` with the reported error fields, backoff
matching Section 11) → ListJobs(`RETRYING`) finds it → KillJob (idempotent on
a second call) → RetryJob (→ `ENQUEUED`, count reset) → UpdateQueue(paused)
(a subsequent Fetch returns empty immediately, not after the poll budget) →
DeleteJob (rejected without `confirm`, rejected from a non-`dead` state,
succeeds once `dead` and confirmed) → GetJob 404s afterward. See
`spec/morganite/jqcp/` for the equivalent automated coverage, run against
real Redis as part of `crystal spec` like the rest of this project's suite.

`~/Projects/job_queue_protocol/JQCP-e2e-test-scenarios.md` (the protocol
author's own scenario catalogue: a smoke test, read-only queries, and 6
numbered scenarios covering happy path, transient failure retry, retry
exhaustion/dead-lettering, worker-crash Lease recovery, operator kill of a
poison-pill job, and idempotency-key deduplication) is implemented in full
as `spec/morganite/jqcp/e2e_scenarios_spec.cr`, with two systematic
adaptations for this Broker's non-streaming transport (documented at the top
of that file) and the one `KillJob`/`SUCCEEDED` deviation noted above. Only
scenario not covered: Beat-driven `RUN_SIGNAL_QUIET`/`RUN_SIGNAL_TERMINATE`
— the source document itself notes this isn't covered by a dedicated
scenario, consistent with the [documented gap](#out-of-scope) that this
Broker never drives Quiet/Terminating server-side.
