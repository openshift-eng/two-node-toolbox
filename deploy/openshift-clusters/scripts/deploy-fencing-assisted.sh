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

# Check if inventory.ini exists
if [[ ! -f "${DEPLOY_DIR}/openshift-clusters/inventory.ini" ]]; then
    echo "Error: inventory.ini not found in ${DEPLOY_DIR}/openshift-clusters/"
    echo "Please ensure the inventory file is properly configured."
    echo "You can run 'make inventory' to update it with current instance information."
    exit 1
fi

# Check if vars/assisted.yml exists
if [[ ! -f "${DEPLOY_DIR}/openshift-clusters/vars/assisted.yml" ]]; then
    echo "Error: vars/assisted.yml not found."
    echo "Copy the template and customize it:"
    echo "  cp config/assisted.yml.template config/assisted.yml"
    echo "(from the repository root; it is synced to vars/assisted.yml on the next run)"
    exit 1
fi

echo "Deploying spoke TNF cluster via assisted installer..."

cd "${DEPLOY_DIR}/openshift-clusters"

# Install required Ansible collections
echo "Installing required Ansible collections..."
ansible-galaxy collection install -r collections/requirements.yml --force-with-deps 2>/dev/null || true

# Parse spoke_cluster_name from vars/assisted.yml
SPOKE_CLUSTER_NAME=$(grep '^spoke_cluster_name:' vars/assisted.yml | awk '{print $2}' | tr -d '"' | tr -d "'")
if [[ -z "${SPOKE_CLUSTER_NAME}" ]]; then
    SPOKE_CLUSTER_NAME="spoke-tnf"
fi

if ansible-playbook assisted-install.yml -i inventory.ini; then
    echo ""
    echo "OpenShift spoke TNF cluster deployment via assisted installer completed successfully!"
    echo ""
    echo "Next steps:"
    echo "1. Access spoke cluster:"
    echo "   source ${DEPLOY_DIR}/openshift-clusters/proxy.env"
    echo "   KUBECONFIG=~/${SPOKE_CLUSTER_NAME}/auth/kubeconfig oc get nodes"
    echo "2. Access hub cluster:"
    echo "   source ${DEPLOY_DIR}/openshift-clusters/hub-proxy.env"
    echo "   KUBECONFIG=~/auth/kubeconfig oc get nodes"
else
    echo "Error: Spoke cluster deployment failed!"
    echo "Check the Ansible logs for more details."
    exit 1
fi
