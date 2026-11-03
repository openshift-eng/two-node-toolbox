#!/usr/bin/env bash

set -e

CONTAINER_ENGINE=${CONTAINER_ENGINE:-podman}
CONTAINER_IMAGE="registry.ci.openshift.org/ci/shellcheck:stable"

if [ "$OPENSHIFT_CI" != "" ]; then
  TOP_DIR="${1:-.}"
  find "${TOP_DIR}" \
    -path "${TOP_DIR}/vendor" -prune \
    -o -type f -name '*.sh' -exec shellcheck --format=gcc {} \+
else
  $CONTAINER_ENGINE run --rm \
    --env OPENSHIFT_CI=TRUE \
    --volume "${PWD}:/workdir:ro,z" \
    --entrypoint sh \
    --workdir /workdir \
    $CONTAINER_IMAGE \
    hack/shellcheck.sh "${@}"
fi;
