#!/usr/bin/env bash

set -euo pipefail

CONTAINER_ENGINE=${CONTAINER_ENGINE:-podman}
CONTAINER_IMAGE="ghcr.io/ansible/community-ansible-dev-tools:latest"
# Host-side cache so the collections download is a one-time cost
COLLECTIONS_CACHE=${COLLECTIONS_CACHE:-${HOME}/.cache/tnt-ansible-collections}
COLLECTIONS_REQUIREMENTS="deploy/openshift-clusters/collections/requirements.yml"

# Directories containing playbooks; syntax-check runs from inside each one so
# ansible.cfg and relative role paths resolve.
PLAYBOOK_DIRS=(
  "deploy/openshift-clusters"
  "helpers"
  "helpers/etcd/playbooks"
)

if [ "${OPENSHIFT_CI:-}" != "" ]; then
  export ANSIBLE_COLLECTIONS_PATH="${COLLECTIONS_CACHE}"

  # One-time download; delete the cache directory to force a refresh after
  # changing collections/requirements.yml.
  if [ ! -d "${COLLECTIONS_CACHE}/ansible_collections" ]; then
    echo "Installing Ansible collections into ${COLLECTIONS_CACHE}..."
    ansible-galaxy collection install \
      -r "${COLLECTIONS_REQUIREMENTS}" \
      -p "${COLLECTIONS_CACHE}"
  fi

  echo "Running ansible-lint..."
  ansible-lint

  REPO_ROOT="${PWD}"
  for DIR in "${PLAYBOOK_DIRS[@]}"; do
    echo "Syntax-checking playbooks in ${DIR}..."
    cd "${REPO_ROOT}/${DIR}"
    shopt -s nullglob
    for PLAYBOOK in *.yml; do
      ansible-playbook --syntax-check "${PLAYBOOK}"
    done
    shopt -u nullglob
  done
  cd "${REPO_ROOT}"
else
  mkdir -p "${COLLECTIONS_CACHE}"
  "${CONTAINER_ENGINE}" run --rm \
    --env OPENSHIFT_CI=TRUE \
    --env COLLECTIONS_CACHE=/var/cache/tnt-ansible-collections \
    --volume "${PWD}:/workdir:z" \
    --volume "${COLLECTIONS_CACHE}:/var/cache/tnt-ansible-collections:z" \
    --entrypoint bash \
    --workdir /workdir \
    "${CONTAINER_IMAGE}" \
    hack/ansible-lint.sh "${@}"
fi
