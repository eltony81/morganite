#!/bin/sh
set -e

# Builds a statically-linked release binary of `morganite`, using the same
# Alpine-based Crystal image as .github/workflows/release.yml so the result
# matches what CI produces for a tagged release, rather than depending on
# whatever libc/library versions happen to be on this machine.
#
# Usage:
#   ./scripts/build_static.sh [output_path]
#
# Override the container runtime or image with:
#   CONTAINER_RUNTIME="docker" ./scripts/build_static.sh
#   CRYSTAL_IMAGE="crystallang/crystal:1.20-alpine" ./scripts/build_static.sh

CONTAINER_RUNTIME="${CONTAINER_RUNTIME:-podman}"
CRYSTAL_IMAGE="${CRYSTAL_IMAGE:-crystallang/crystal:1.20-alpine}"
OUTPUT="${1:-bin/morganite}"

mkdir -p "$(dirname "$OUTPUT")"

echo "Building static binary with $CRYSTAL_IMAGE -> $OUTPUT"

$CONTAINER_RUNTIME run --rm \
  -v "$(pwd):/app:Z" \
  -w /app \
  "$CRYSTAL_IMAGE" \
  sh -c "shards install --production && crystal build src/morganite/cli_main.cr -o '$OUTPUT' --release --static --no-debug"

echo "Done: $OUTPUT"
file "$OUTPUT" 2>/dev/null || true
