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

# Check if inventory.ini exists in the openshift-clusters directory
if [[ ! -f "${DEPLOY_DIR}/openshift-clusters/inventory.ini" ]]; then
    echo "Error: inventory.ini not found in ${DEPLOY_DIR}/openshift-clusters/"
    echo "Please ensure the inventory file is properly configured."
    echo "You can run 'make inventory' to update it with current instance information."
    exit 1
fi

# Get the helpers directory (one level up from deploy)
HELPERS_DIR="$(cd "${DEPLOY_DIR}/.." && pwd)/helpers"

# Default RPM version
RPM_VERSION="${1:-4.11}"

echo "Building and patching resource-agents on cluster nodes..."
echo "RPM Version: ${RPM_VERSION}"
echo ""

# Navigate to the helpers directory and run the build-and-patch playbook
cd "${HELPERS_DIR}"

# Run the build-and-patch playbook
if ansible-playbook -i "${DEPLOY_DIR}/openshift-clusters/inventory.ini" \
    build-and-patch-resource-agents.yml \
    -e "rpm_version=${RPM_VERSION}"; then
    echo ""
    echo "✓ Resource-agents build and patch completed successfully!"
    echo ""
    echo "The RPM has been built on the hypervisor and installed on all cluster nodes."
    echo "Cluster nodes have been rebooted to apply the changes."
    echo ""
    echo "RPM location: ${HELPERS_DIR}/resource-agents-${RPM_VERSION}-1.el9.x86_64.rpm"
else
    echo "Error: Resource-agents build and patch failed!"
    echo "Check the Ansible logs for more details."
    exit 1
fi
