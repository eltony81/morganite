#!/bin/sh
set -e

# Run the load test suite using podman-compose by default.
# Override with: DOCKER_COMPOSE="docker-compose" ./scripts/run_load_test.sh
# Override job count/timeout with: JOB_COUNT=50000 TIMEOUT_SECONDS=300 ./scripts/run_load_test.sh

DOCKER_COMPOSE="${DOCKER_COMPOSE:-podman-compose}"
COMPOSE_FILE="docker-compose.load.yml"

echo "Running load test with: $DOCKER_COMPOSE -f $COMPOSE_FILE"
$DOCKER_COMPOSE -f "$COMPOSE_FILE" down -v
$DOCKER_COMPOSE -f "$COMPOSE_FILE" up --build --abort-on-container-exit
$DOCKER_COMPOSE -f "$COMPOSE_FILE" down -v
