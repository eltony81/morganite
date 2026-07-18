#!/bin/sh
set -e

# Stress test: flood the queue, then hard-kill one of two worker processes
# mid-flight to prove OrphanReaper recovers its abandoned jobs and the
# survivor still fully drains the flood.
#
# Defaults to podman-compose/podman. Override with:
#   DOCKER_COMPOSE="docker-compose" CONTAINER_CLI="docker" ./scripts/run_stress_test.sh
# Override job count/timeout with:
#   JOB_COUNT=200000 TIMEOUT_SECONDS=600 ./scripts/run_stress_test.sh

DOCKER_COMPOSE="${DOCKER_COMPOSE:-podman-compose}"
CONTAINER_CLI="${CONTAINER_CLI:-podman}"
COMPOSE_FILE="docker-compose.stress.yml"
# These defaults are only used for the log line below; the actual values
# used inside the containers come from docker-compose.stress.yml's own
# defaults, which must be kept in sync with these.
JOB_COUNT="${JOB_COUNT:-5000}"
TIMEOUT_SECONDS="${TIMEOUT_SECONDS:-300}"
# podman-compose (this version) doesn't support `ps -q <service>`, so
# container names are derived the same way it derives them itself:
# <project>_<service>_1, project defaulting to the compose-file directory's
# basename. Override with COMPOSE_PROJECT_NAME if that doesn't match.
PROJECT_NAME="${COMPOSE_PROJECT_NAME:-$(basename "$PWD")}"
WORKER_NAME="${PROJECT_NAME}_worker_1"
LOAD_NAME="${PROJECT_NAME}_load_1"

echo "=== Morganite stress test (flood + hard-kill a worker mid-flight) ==="
echo "Using: $DOCKER_COMPOSE / $CONTAINER_CLI -f $COMPOSE_FILE (JOB_COUNT=$JOB_COUNT, TIMEOUT_SECONDS=$TIMEOUT_SECONDS)"

cleanup() {
  $DOCKER_COMPOSE -f "$COMPOSE_FILE" down -v >/dev/null 2>&1 || true
}
trap cleanup EXIT

$DOCKER_COMPOSE -f "$COMPOSE_FILE" down -v
$DOCKER_COMPOSE -f "$COMPOSE_FILE" build

echo "--- Starting redis + two workers ---"
$DOCKER_COMPOSE -f "$COMPOSE_FILE" up -d redis worker worker2

echo "--- Starting the flood (enqueueing $JOB_COUNT jobs) ---"
$DOCKER_COMPOSE -f "$COMPOSE_FILE" up -d load

echo "Letting the flood build a backlog for 5s, then hard-killing '$WORKER_NAME' (SIGKILL, no graceful shutdown)..."
sleep 5
if ! $CONTAINER_CLI inspect "$WORKER_NAME" >/dev/null 2>&1; then
  echo "FAILURE: could not find container '$WORKER_NAME' to kill"
  exit 1
fi
$CONTAINER_CLI kill -s SIGKILL "$WORKER_NAME"

echo "--- Waiting for '$LOAD_NAME' to finish draining via worker2 + OrphanReaper ---"
while [ "$($CONTAINER_CLI inspect -f '{{.State.Running}}' "$LOAD_NAME")" = "true" ]; do
  sleep 2
done

LOAD_EXIT="$($CONTAINER_CLI inspect -f '{{.State.ExitCode}}' "$LOAD_NAME")"
$DOCKER_COMPOSE -f "$COMPOSE_FILE" logs load

if [ "$LOAD_EXIT" != "0" ]; then
  echo "FAILURE: flood+kill scenario did not drain successfully (load exited $LOAD_EXIT)"
  exit 1
fi

# The primary correctness property (zero job loss) already held above. This
# is an extra, informative check: did we actually witness OrphanReaper
# recover something, or did the survivor happen to finish the flood before
# any job was truly caught mid-flight on the killed worker? Recovery of a
# genuine orphan can take up to ~45s (the heartbeat TTL in launcher.cr), so
# this checks the full compose logs, not just what's scrolled by so far.
if $DOCKER_COMPOSE -f "$COMPOSE_FILE" logs worker2 2>/dev/null | grep -q "orphan reaper: requeued"; then
  echo "=== SUCCESS: flood fully drained, AND OrphanReaper was observed recovering jobs from the killed worker ==="
else
  echo "=== SUCCESS: flood fully drained with zero job loss, but OrphanReaper recovery was not observed in this run ==="
  echo "(the killed worker may not have had any job genuinely in flight at the moment it was killed — re-run, or lower the pre-kill sleep, to increase the odds)"
fi
