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

# Parse optional parameters
GRAFANA_ENABLED="${1:-true}"

echo "Deploying Kepler power monitoring on TNF cluster..."
echo ""
echo "Options:"
echo "  Grafana dashboard: ${GRAFANA_ENABLED}"
echo ""

# Navigate to the openshift-clusters directory
cd "${DEPLOY_DIR}/openshift-clusters"

# Run the Kepler deployment playbook
if ansible-playbook kepler.yml -i inventory.ini -e "grafana_enabled=${GRAFANA_ENABLED}"; then
    echo ""
    echo "=============================================="
    echo "Kepler power monitoring deployed successfully!"
    echo "=============================================="
    echo ""
    echo "Access Grafana dashboard:"
    echo "  1. Set up port-forward:"
    echo "     source proxy.env"
    echo "     oc port-forward -n grafana svc/grafana 3000:3000"
    echo ""
    echo "  2. Open in browser: http://localhost:3000"
    echo "     Dashboard: TNF Power Monitoring"
    echo ""
    echo "Query metrics via CLI:"
    echo "  oc exec -n openshift-user-workload-monitoring prometheus-user-workload-0 -c prometheus -- \\"
    echo "    curl -s 'http://localhost:9090/api/v1/query?query=sum(kepler_node_cpu_watts)'"
    echo ""
    echo "Remove Kepler:"
    echo "  make remove-kepler"
    echo ""
else
    echo ""
    echo "Error: Kepler deployment failed!"
    echo ""
    echo "Troubleshooting:"
    echo "  1. Check cluster access: oc get nodes"
    echo "  2. Check KUBECONFIG is set or proxy.env is sourced"
    echo "  3. View Kepler pods: oc get pods -n kepler"
    echo ""
    exit 1
fi
