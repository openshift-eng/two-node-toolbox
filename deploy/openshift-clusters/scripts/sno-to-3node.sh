#!/usr/bin/bash
set -euo pipefail

SCRIPT_DIR=$(dirname "$0")
DEPLOY_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"

# shellcheck source=/dev/null
source "${DEPLOY_DIR}/aws-hypervisor/scripts/common.sh"

if [[ ! -f "$(get_node_dir)/aws-instance-id" ]]; then
    echo "Error: No instance found. Run 'make deploy' first."
    exit 1
fi

if [[ ! -f "${DEPLOY_DIR}/openshift-clusters/inventory.ini" ]]; then
    echo "Error: inventory.ini not found. Run 'make inventory' first."
    exit 1
fi

cd "${DEPLOY_DIR}/openshift-clusters"
ansible-playbook sno-to-3node.yml -e "interactive_mode=false" -i inventory.ini "$@"
