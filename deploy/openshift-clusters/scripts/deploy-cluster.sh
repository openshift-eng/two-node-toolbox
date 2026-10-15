#!/usr/bin/env bash
#
# Unified cluster deployment script
# Usage: deploy-cluster.sh --topology <arbiter|fencing> --method <ipi|agent|kcli>
#

# Get the directory where this script is located
SCRIPT_DIR=$(dirname "$0")
# Get the deploy directory (two levels up from scripts)
DEPLOY_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"

# shellcheck source=/dev/null
source "${DEPLOY_DIR}/common.sh"

set -o nounset
set -o errexit
set -o pipefail

# Default values
TOPOLOGY=""
METHOD=""

# Parse command line arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --topology)
            TOPOLOGY="$2"
            shift 2
            ;;
        --method)
            METHOD="$2"
            shift 2
            ;;
        -h|--help)
            echo "Usage: $0 --topology <arbiter|fencing> --method <ipi|agent|kcli>"
            echo ""
            echo "Options:"
            echo "  --topology   Cluster topology: arbiter or fencing"
            echo "  --method     Deployment method: ipi, agent, or kcli"
            exit 0
            ;;
        *)
            echo "Error: Unknown option: $1"
            echo "Run '$0 --help' for usage information."
            exit 1
            ;;
    esac
done

# Validate required arguments
if [[ -z "${TOPOLOGY}" ]]; then
    echo "Error: --topology is required (arbiter, fencing, or sno)"
    exit 1
fi

if [[ -z "${METHOD}" ]]; then
    echo "Error: --method is required (ipi, agent, or kcli)"
    exit 1
fi

# Validate topology value
if [[ "${TOPOLOGY}" != "arbiter" && "${TOPOLOGY}" != "fencing" && "${TOPOLOGY}" != "sno" ]]; then
    echo "Error: Invalid topology '${TOPOLOGY}'. Must be 'arbiter', 'fencing', or 'sno'."
    exit 1
fi

# Validate method value
if [[ "${METHOD}" != "ipi" && "${METHOD}" != "agent" && "${METHOD}" != "kcli" ]]; then
    echo "Error: Invalid method '${METHOD}'. Must be 'ipi', 'agent', or 'kcli'."
    exit 1
fi

# Check if instance data exists
if [[ ! -f "$(get_node_dir)/aws-instance-id" ]]; then
    echo "Error: No instance found. Please run 'make deploy' first."
    echo "Run 'make doctor' to check your setup."
    exit 1
fi

# Check if inventory.ini exists in the openshift-clusters directory
if [[ ! -f "${DEPLOY_DIR}/openshift-clusters/inventory.ini" ]]; then
    echo "Error: inventory.ini not found in ${DEPLOY_DIR}/openshift-clusters/"
    echo "Please ensure the inventory file is properly configured."
    echo "You can run 'make inventory' to update it with current instance information."
    echo "Run 'make doctor' to check your setup."
    exit 1
fi

# Determine playbook and extra variables based on method
case "${METHOD}" in
    ipi)
        PLAYBOOK="setup.yml"
        EXTRA_VARS=(-e "topology=${TOPOLOGY}" -e "interactive_mode=false")
        METHOD_DISPLAY="IPI"
        ;;
    agent)
        PLAYBOOK="setup.yml"
        EXTRA_VARS=(-e "topology=${TOPOLOGY}" -e "interactive_mode=false" -e "method=agent")
        METHOD_DISPLAY="agent"
        ;;
    kcli)
        PLAYBOOK="kcli-install.yml"
        EXTRA_VARS=(-e "topology=${TOPOLOGY}" -e "interactive_mode=false")
        METHOD_DISPLAY="kcli"
        ;;
esac

echo "Deploying ${TOPOLOGY} cluster using ${METHOD_DISPLAY} method..."

# Navigate to the openshift-clusters directory
cd "${DEPLOY_DIR}/openshift-clusters"

echo "Running Ansible ${PLAYBOOK} playbook with ${TOPOLOGY} topology in non-interactive mode..."

# Run the playbook
if ansible-playbook "${PLAYBOOK}" "${EXTRA_VARS[@]}" -i inventory.ini; then
    echo ""
    echo "OpenShift ${TOPOLOGY} cluster deployment (${METHOD_DISPLAY}) completed successfully!"
    print_proxy_instructions
else
    echo "Error: OpenShift cluster deployment failed!"
    echo "Check the Ansible logs for more details."
    exit 1
fi
