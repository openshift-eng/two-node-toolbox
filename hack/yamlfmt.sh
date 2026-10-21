#!/usr/bin/bash

set -euo pipefail

CONTAINER_ENGINE=${CONTAINER_ENGINE:-podman}
CONTAINER_IMAGE="ghcr.io/google/yamlfmt:latest"
FMT_CONFIG=".yamlfmt"
VALIDATE_ONLY=${VALIDATE_ONLY:-false}
VALIDATE_ONLY_FLAG_ARGS="--lint"
EXTRA_FLAG_ARGS=""

if [ "$VALIDATE_ONLY" != "false" ]; then
  EXTRA_FLAG_ARGS="$VALIDATE_ONLY_FLAG_ARGS"
fi


if [ "${OPENSHIFT_CI:-}" != "" ]; then
  TOP_DIR="${1:-.}"
  yamlfmt -conf "$FMT_CONFIG" "$EXTRA_FLAG_ARGS" "$TOP_DIR"
else
  $CONTAINER_ENGINE run --rm \
    --env OPENSHIFT_CI=TRUE \
    --env VALIDATE_ONLY="$VALIDATE_ONLY" \
    --volume "${PWD}:/workdir:z" \
    --entrypoint sh \
    --workdir /workdir \
    $CONTAINER_IMAGE \
    hack/yamlfmt.sh "${@}"
fi
