#!/usr/bin/env bash

# Get the directory where this script is located
SCRIPT_DIR=$(dirname "$0")
# Get the deploy directory (two levels up from scripts)
DEPLOY_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"

# shellcheck source=/dev/null
source "${DEPLOY_DIR}/common.sh"

set -o nounset
set -o errexit
set -o pipefail

# Check if instance data exists
if [[ ! -f "$(get_node_dir)/aws-instance-id" ]]; then
    echo "Error: No instance found. Please run 'make deploy' first."
    exit 1
fi

echo "Full cleaning OpenShift cluster (using 'realclean' target)..."

# Check if inventory.ini exists in the openshift-clusters directory
if [[ ! -f "${DEPLOY_DIR}/openshift-clusters/inventory.ini" ]]; then
    echo "Error: inventory.ini not found in ${DEPLOY_DIR}/openshift-clusters/"
    echo "Please ensure the inventory file is properly configured."
    echo "You can run 'make inventory' to update it with current instance information."
    exit 1
fi

# Navigate to the openshift-clusters directory and run the clean playbook
echo "Running Ansible clean playbook with complete=true option..."
cd "${DEPLOY_DIR}/openshift-clusters"

# Run the clean playbook with complete=true (runs 'realclean' target)
set +e
ansible-playbook clean.yml -i inventory.ini --extra-vars "complete=true"
rc=$?

clear_cluster_state
set -e

if [[ $rc -eq 0 ]]; then
    echo ""
    echo "✓ OpenShift cluster full clean completed successfully!"
else
    echo "Remote cluster full clean reported errors (exit code $rc)."
    echo "Local cluster state has been cleared."
fi

exit $rc 