#!/bin/sh
set -e

# Run the end-to-end suite using podman-compose by default.
# Override with: DOCKER_COMPOSE="docker-compose" ./scripts/run_e2e.sh

DOCKER_COMPOSE="${DOCKER_COMPOSE:-podman-compose}"
COMPOSE_FILE="docker-compose.e2e.yml"

echo "Running E2E with: $DOCKER_COMPOSE -f $COMPOSE_FILE"
$DOCKER_COMPOSE -f "$COMPOSE_FILE" down -v
$DOCKER_COMPOSE -f "$COMPOSE_FILE" up --build --abort-on-container-exit
$DOCKER_COMPOSE -f "$COMPOSE_FILE" down -v
