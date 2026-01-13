#!/bin/bash

# Get the directory where this script is located
SCRIPT_DIR=$(dirname "$0")
# Get the deploy directory (two levels up from scripts)
DEPLOY_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"

set -o nounset
set -o errexit
set -o pipefail

# Get deployment ID from environment or use default
DEPLOYMENT_ID="${DEPLOYMENT_ID:-${USER}-dev}"
INSTANCE_DATA_DIR="${DEPLOY_DIR}/aws-hypervisor/instance-data-${DEPLOYMENT_ID}"
DEPLOYMENT_DIR="${DEPLOY_DIR}/openshift-clusters/deployments/${DEPLOYMENT_ID}"
INVENTORY_FILE="${DEPLOYMENT_DIR}/inventory.ini"

echo "Deployment ID: ${DEPLOYMENT_ID}"

# Check if instance data exists
if [[ ! -f "${INSTANCE_DATA_DIR}/aws-instance-id" ]]; then
    echo "Error: No instance found for deployment '${DEPLOYMENT_ID}'."
    echo "Please run 'make deploy DEPLOYMENT_ID=${DEPLOYMENT_ID}' first."
    exit 1
fi

echo "Deploying arbiter IPI cluster for deployment '${DEPLOYMENT_ID}'..."

# Check if inventory.ini exists
if [[ ! -f "${INVENTORY_FILE}" ]]; then
    echo "Error: inventory.ini not found at ${INVENTORY_FILE}"
    echo "Please ensure the inventory file is properly configured."
    echo "You can run 'make inventory DEPLOYMENT_ID=${DEPLOYMENT_ID}' to update it."
    exit 1
fi

# Navigate to the openshift-clusters directory and run the setup playbook
echo "Running Ansible setup playbook with arbiter topology in non-interactive mode..."
cd "${DEPLOY_DIR}/openshift-clusters"

# Run the setup playbook with arbiter topology and non-interactive mode
if ansible-playbook setup.yml -e "topology=arbiter" -e "interactive_mode=false" -i "${INVENTORY_FILE}"; 
then
    echo ""
    echo "✓ OpenShift arbiter cluster deployment completed successfully!"
    echo ""
    echo "Next steps:"
    echo "1. Source the proxy environment for deployment '${DEPLOYMENT_ID}':"
    echo "   source ${DEPLOYMENT_DIR}/proxy.env"
    echo "2. Verify cluster access: oc get nodes"
    echo "3. Access the cluster console if needed"
else
    echo "Error: OpenShift cluster deployment failed!"
    echo "Check the Ansible logs for more details."
    exit 1
fi 