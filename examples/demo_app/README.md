# Demo App – Morganite E2E

This is a minimal Crystal application used to run end-to-end tests against Morganite.

It currently uses Redis directly to simulate a producer/consumer queue. As Morganite APIs become available, this app will be migrated to use `Morganite::Client` and `Morganite::Worker`.

## Commands

```bash
# Enqueue jobs (default 100)
crystal run src/demo_app.cr -- enqueue 100

# Run worker
crystal run src/demo_app.cr -- work

# Run E2E orchestrator
crystal run src/e2e.cr
```

## E2E with Docker/Podman

From the project root:

```bash
# Docker
DOCKER_COMPOSE="docker-compose -f docker-compose.e2e.yml"
$DOCKER_COMPOSE up --build --abort-on-container-exit

# Podman
podman-compose -f docker-compose.e2e.yml up --build --abort-on-container-exit
```

The `e2e` service exits with code 0 on success or 1 on failure.
