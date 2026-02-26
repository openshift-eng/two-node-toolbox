#!/bin/bash

# Get the directory where this script is located
SCRIPT_DIR=$(dirname "$0")
# Get the deploy directory (two levels up from scripts)
DEPLOY_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"

set -o nounset
set -o errexit
set -o pipefail

# Check if inventory.ini exists in the openshift-clusters directory
if [[ ! -f "${DEPLOY_DIR}/openshift-clusters/inventory.ini" ]]; then
    echo "Error: inventory.ini not found in ${DEPLOY_DIR}/openshift-clusters/"
    echo "Please ensure the inventory file is properly configured."
    exit 1
fi

echo "Removing Kepler power monitoring from TNF cluster..."
echo ""

# Navigate to the openshift-clusters directory
cd "${DEPLOY_DIR}/openshift-clusters"

# Run the Kepler removal playbook
if ansible-playbook kepler.yml -i inventory.ini -e "kepler_state=absent"; then
    echo ""
    echo "=========================================="
    echo "Kepler power monitoring removed successfully!"
    echo "=========================================="
    echo ""
    echo "The following resources have been cleaned up:"
    echo "  - Kepler DaemonSet and Service"
    echo "  - Kepler namespace"
    echo "  - Grafana deployment and namespace"
    echo "  - ServiceMonitor and RBAC resources"
    echo ""
    echo "To redeploy Kepler:"
    echo "  make deploy-kepler"
    echo ""
else
    echo ""
    echo "Error: Kepler removal failed!"
    echo ""
    echo "Troubleshooting:"
    echo "  1. Check cluster access: oc get nodes"
    echo "  2. Manually check namespaces: oc get ns | grep -E 'kepler|grafana'"
    echo "  3. Force delete if stuck: oc delete ns kepler grafana --force"
    echo ""
    exit 1
fi
