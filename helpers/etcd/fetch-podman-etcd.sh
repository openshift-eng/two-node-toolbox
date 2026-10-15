#!/usr/bin/env bash
# Fetch the latest podman-etcd resource agent from upstream ClusterLabs
#
# This script downloads the podman-etcd resource agent from the ClusterLabs
# resource-agents repository and saves it for reference in the etcd
# troubleshooting documentation.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
TARGET_FILE="${REPO_ROOT}/.claude/commands/etcd/pacemaker/podman-etcd.txt"
UPSTREAM_URL="https://raw.githubusercontent.com/ClusterLabs/resource-agents/main/heartbeat/podman-etcd"

echo "Fetching podman-etcd resource agent from upstream..."
echo "URL: ${UPSTREAM_URL}"

if command -v curl &>/dev/null; then
    curl -fsSL "${UPSTREAM_URL}" -o "${TARGET_FILE}"
elif command -v wget &>/dev/null; then
    wget -q "${UPSTREAM_URL}" -O "${TARGET_FILE}"
else
    echo "Error: curl or wget required" >&2
    exit 1
fi

echo "Saved to: ${TARGET_FILE}"
echo "Done."
