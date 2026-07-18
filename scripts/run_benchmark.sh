#!/bin/sh
set -e

# Benchmarks Morganite against Sidekiq: same job count, same concurrency,
# same measurement approach (each side's own dedicated connection pool,
# incr + incrbyfloat per job to record throughput/latency), run sequentially
# against a fresh Redis each so neither run competes with the other for CPU.
# Streams both runs' output live, then prints a side-by-side results table.
#
# Defaults to podman-compose. Override with:
#   DOCKER_COMPOSE="docker-compose" ./scripts/run_benchmark.sh
# Override job count/concurrency/timeout with:
#   JOB_COUNT=50000 CONCURRENCY=25 TIMEOUT_SECONDS=300 ./scripts/run_benchmark.sh

DOCKER_COMPOSE="${DOCKER_COMPOSE:-podman-compose}"
JOB_COUNT="${JOB_COUNT:-20000}"
CONCURRENCY="${CONCURRENCY:-10}"
TIMEOUT_SECONDS="${TIMEOUT_SECONDS:-180}"
# Exported (not just prefixed onto individual commands) so docker-compose's
# ${VAR:-default} interpolation reliably sees them regardless of how a given
# `sh` implementation scopes variable assignments prefixed onto a function
# call — that's unspecified enough across shells to not rely on.
export JOB_COUNT CONCURRENCY TIMEOUT_SECONDS

MORGANITE_LOG="$(mktemp)"
SIDEKIQ_LOG="$(mktemp)"
EXIT_CODE_FILE="$(mktemp)"
MORGANITE_EXIT=0
SIDEKIQ_EXIT=0

# All of the project's compose files share host port 6379 for redis, so a
# stack left running from an e2e/load/stress run (or an interrupted earlier
# benchmark) would block this one from starting. Stop every one of them,
# not just the two this script uses, both before starting and on exit.
stop_all_compose_stacks() {
  for f in docker-compose.yml docker-compose.e2e.yml docker-compose.load.yml \
    docker-compose.stress.yml docker-compose.bench-morganite.yml docker-compose.bench-sidekiq.yml; do
    if [ -f "$f" ]; then
      $DOCKER_COMPOSE -f "$f" down -v >/dev/null 2>&1 || true
    fi
  done
}

cleanup() {
  echo ""
  echo "--- Shutting down docker compose ---"
  stop_all_compose_stacks
  rm -f "$MORGANITE_LOG" "$SIDEKIQ_LOG" "$EXIT_CODE_FILE"
}
trap cleanup EXIT

# Runs a compose file's `up --abort-on-container-exit`, streaming its output
# live to the terminal (via tee) while also saving it to log_file. The exit
# code is written to EXIT_CODE_FILE, not returned by this function: piping
# into tee makes `$?` reflect tee's exit status rather than the compose
# command's (POSIX sh has no PIPESTATUS/pipefail to rely on here), and this
# must be *called* directly rather than through `$(...)` — capturing a
# function's output via command substitution would swallow the live stream
# tee is supposed to be sending to the terminal.
run_compose() {
  compose_file="$1"
  log_file="$2"

  { $DOCKER_COMPOSE -f "$compose_file" up --abort-on-container-exit
    echo $? > "$EXIT_CODE_FILE"
  } 2>&1 | tee "$log_file"
}

echo "=== Morganite vs Sidekiq benchmark ==="
echo "JOB_COUNT=$JOB_COUNT CONCURRENCY=$CONCURRENCY TIMEOUT_SECONDS=$TIMEOUT_SECONDS"
echo "Using: $DOCKER_COMPOSE"

echo ""
echo "--- Stopping any compose stacks already running (redis port 6379 is shared) ---"
stop_all_compose_stacks

echo ""
echo "--- Building and running Morganite ---"
$DOCKER_COMPOSE -f docker-compose.bench-morganite.yml build
run_compose docker-compose.bench-morganite.yml "$MORGANITE_LOG"
MORGANITE_EXIT="$(cat "$EXIT_CODE_FILE")"

echo ""
echo "--- Stopping Morganite, restarting for Sidekiq ---"
$DOCKER_COMPOSE -f docker-compose.bench-morganite.yml down -v >/dev/null 2>&1 || true

echo ""
echo "--- Building and running Sidekiq ---"
$DOCKER_COMPOSE -f docker-compose.bench-sidekiq.yml build
run_compose docker-compose.bench-sidekiq.yml "$SIDEKIQ_LOG"
SIDEKIQ_EXIT="$(cat "$EXIT_CODE_FILE")"

echo ""
echo "--- Stopping Sidekiq ---"
$DOCKER_COMPOSE -f docker-compose.bench-sidekiq.yml down -v >/dev/null 2>&1 || true

extract() {
  # extract <pattern> <log file> — the last number in the last line matching
  # pattern. "drained N/N jobs in X.Xs" has three numbers in it; without the
  # trailing `tail -1`, this would print all three instead of just X.X.
  grep -oE "$1" "$2" | tail -1 | grep -oE '[0-9]+(\.[0-9]+)?' | tail -1
}

M_THROUGHPUT="$(extract 'throughput:[[:space:]]*[0-9.]+ jobs/sec' "$MORGANITE_LOG")"
M_LATENCY="$(extract 'avg latency:[[:space:]]*[0-9.]+ms' "$MORGANITE_LOG")"
M_DRAIN="$(extract 'drained [0-9]+/[0-9]+ jobs in [0-9.]+s' "$MORGANITE_LOG")"
S_THROUGHPUT="$(extract 'throughput:[[:space:]]*[0-9.]+ jobs/sec' "$SIDEKIQ_LOG")"
S_LATENCY="$(extract 'avg latency:[[:space:]]*[0-9.]+ms' "$SIDEKIQ_LOG")"
S_DRAIN="$(extract 'drained [0-9]+/[0-9]+ jobs in [0-9.]+s' "$SIDEKIQ_LOG")"

echo ""
echo "=== Results (JOB_COUNT=$JOB_COUNT, CONCURRENCY=$CONCURRENCY) ==="
echo ""
printf '%-22s %18s %18s\n' "" "Morganite" "Sidekiq"
printf '%-22s %18s %18s\n' "Throughput (jobs/s)" "${M_THROUGHPUT:-n/a}" "${S_THROUGHPUT:-n/a}"
printf '%-22s %18s %18s\n' "Drain time (s)" "${M_DRAIN:-n/a}" "${S_DRAIN:-n/a}"
printf '%-22s %18s %18s\n' "Avg latency (ms)" "${M_LATENCY:-n/a}" "${S_LATENCY:-n/a}"
echo ""
echo "Full output:"
echo "--- Morganite ---"
grep '\[load\]' "$MORGANITE_LOG" | sed 's/^.*\[load\]/  [load]/'
echo "--- Sidekiq ---"
grep '\[sidekiq-bench\]' "$SIDEKIQ_LOG" | sed 's/^.*\[sidekiq-bench\]/  [sidekiq-bench]/'

if [ "$MORGANITE_EXIT" != "0" ] || [ "$SIDEKIQ_EXIT" != "0" ]; then
  echo ""
  echo "One or both runs did not complete successfully (morganite exit=$MORGANITE_EXIT, sidekiq exit=$SIDEKIQ_EXIT)."
  exit 1
fi
