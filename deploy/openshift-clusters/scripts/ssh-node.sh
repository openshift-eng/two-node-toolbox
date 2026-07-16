#!/bin/bash

set -euo pipefail

SCRIPT_DIR=$(dirname "$0")
DEPLOY_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"
INVENTORY_FILE="${DEPLOY_DIR}/openshift-clusters/inventory.ini"

usage() {
    echo "Usage: $0 <node> [command]"
    echo ""
    echo "SSH into a cluster node via the hypervisor jump host."
    echo "If a command is provided, execute it and return."
    echo ""
    echo "Node can be specified as:"
    echo "  master-0, master_0, node0, 0  -> first master node"
    echo "  master-1, master_1, node1, 1  -> second master node"
    echo ""
    echo "Examples:"
    echo "  $0 master-0              # Interactive SSH session"
    echo "  $0 0 uptime              # Run 'uptime' on master-0"
    echo "  $0 1 'pcs status'        # Run 'pcs status' on master-1"
    exit 1
}

if [[ $# -lt 1 ]]; then
    usage
fi

NODE_ARG="$1"
shift

# Check if inventory file exists
if [[ ! -f "${INVENTORY_FILE}" ]]; then
    echo "Error: Inventory file not found at ${INVENTORY_FILE}"
    echo "Run 'make inventory' first."
    exit 1
fi

# Normalize node argument to inventory name
case "${NODE_ARG}" in
    master-0|master_0|node0|0)
        NODE_PATTERN="master_0"
        ;;
    master-1|master_1|node1|1)
        NODE_PATTERN="master_1"
        ;;
    *)
        echo "Error: Unknown node '${NODE_ARG}'"
        usage
        ;;
esac

# Extract node IP from inventory
# NOTE: Preventing this command to fail with `|| true`. The script setting at the top will make it exit immediately in case of failure.
NODE_IP=$(grep -W "master_0|master_1" "${INVENTORY_FILE}" | grep "${NODE_PATTERN}" | grep -oP "ansible_host='\\K[^']+" || true)
if [[ -z "${NODE_IP}" ]]; then
    echo "Error: Could not find ${NODE_PATTERN} in inventory"
    echo "Make sure the cluster is deployed and inventory is updated."
    exit 1
fi

# Extract hypervisor info from inventory
# NOTE: Preventing this command to fail with `|| true`. The script setting at the top will make it exit immediately in case of failure.
HYPERVISOR=$(awk '/^\[metal_machine\]/{found=1;next} /^\[/{found=0} found && /@/{print $1; exit}' "${INVENTORY_FILE}" || true)
if [[ -z "${HYPERVISOR}" ]]; then
    echo "Error: Could not find hypervisor in inventory"
    exit 1
fi

# Common SSH options to avoid known_hosts issues after redeploys
SSH_OPTS=(
    -o StrictHostKeyChecking=no
    -o UserKnownHostsFile=/dev/null
    -o LogLevel=WARN
)

# ProxyJump with same options for the jump host
PROXY_CMD="ssh ${SSH_OPTS[*]} -W %h:%p ${HYPERVISOR}"

if [[ $# -gt 0 ]]; then
    # Run command and return
    ssh "${SSH_OPTS[@]}" \
        -o "ProxyCommand=${PROXY_CMD}" \
        "core@${NODE_IP}" "$@"
else
    # Interactive session
    echo "Connecting to ${NODE_PATTERN} (${NODE_IP}) via ${HYPERVISOR}..."
    ssh "${SSH_OPTS[@]}" \
        -o "ProxyCommand=${PROXY_CMD}" \
        "core@${NODE_IP}"
fi
