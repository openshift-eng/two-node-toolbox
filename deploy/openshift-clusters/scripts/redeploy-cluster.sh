#!/usr/bin/env bash

# Get the directory where this script is located
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEPLOY_DIR="$(cd "${SCRIPT_DIR}/../../" && pwd)"

# shellcheck source=/dev/null
source "${DEPLOY_DIR}/common.sh"

set -o nounset
set -o errexit
set -o pipefail

NODE_DIR="$(get_node_dir)"

# Function: Check if VM infrastructure needs to change and determine cleanup strategy
check_vm_infrastructure_change() {
    local topology="$1"
    local state_file
    state_file="$(get_shared_dir)/cluster-vm-state.json"
    local current_topology="$topology"
    local previous_topology=""
    local previous_installation_method=""
    local previous_status=""
    
    echo "Checking VM infrastructure requirements for instance ${INSTANCE_ID}..."
    
    # Read previous state if exists
    if [[ -f "$state_file" ]]; then
        if command -v jq >/dev/null 2>&1; then
            previous_topology=$(jq -r '.topology // ""' "$state_file" 2>/dev/null || echo "")
            previous_installation_method=$(jq -r '.installation_method // ""' "$state_file" 2>/dev/null || echo "")
            previous_status=$(jq -r '.status // ""' "$state_file" 2>/dev/null || echo "")
        else
            echo "Warning: jq not found, falling back to basic parsing"
            previous_topology=$(grep -o '"topology":[[:space:]]*"[^"]*"' "$state_file" | cut -d'"' -f4 2>/dev/null || echo "")
            previous_installation_method=$(grep -o '"installation_method":[[:space:]]*"[^"]*"' "$state_file" | cut -d'"' -f4 2>/dev/null || echo "")
            previous_status=$(grep -o '"status":[[:space:]]*"[^"]*"' "$state_file" | cut -d'"' -f4 2>/dev/null || echo "")
        fi
    fi

    # Use previous method if available, default to IPI for first deployment
    if [[ -n "$previous_installation_method" ]]; then
        export current_installation_method="$previous_installation_method"
    else
        export current_installation_method="IPI"
    fi

    echo "Instance: ${INSTANCE_ID}"
    echo "Previous cluster config: ${previous_topology:-none}/${previous_installation_method:-none} (status: ${previous_status:-unknown})"
    echo "Current cluster config: ${current_topology}/${current_installation_method}"
    
    # Handle first deployment case (no previous state)
    if [[ -z "$previous_topology" || -z "$previous_installation_method" ]]; then
        echo "No previous cluster state found - assuming this is the first deployment"
        echo "VM infrastructure will be preserved (no cleanup needed)"
        export vm_cleanup_needed="false"
        export clean_needed="false"
        export cleanup_reason="first_deployment"
        return 1  # No cleanup needed
    fi
    
    # Check for topology/method changes
    if [[ "$current_topology" != "$previous_topology" || "$current_installation_method" != "$previous_installation_method" ]]; then
        echo "VM infrastructure change detected (${previous_topology}/${previous_installation_method} → ${current_topology}/${current_installation_method})"
        echo "Complete rebuild required (realclean)"
        export vm_cleanup_needed="true"
        export clean_needed="false"  # realclean includes clean
        export cleanup_reason="topology_change"
        return 0  # Realclean needed
    fi
    
    # Same topology - check deployment status
    case "$previous_status" in
        "deploying")
            echo "Same topology but previous deployment was incomplete (status: deploying)"
            echo "Clean deployment required to recover from incomplete state"
            export vm_cleanup_needed="false"
            export clean_needed="true" 
            export cleanup_reason="incomplete_deployment"
            return 0  # Clean needed
            ;;
        "deployed")
            echo "Same topology and previous deployment was successful"
            echo "Fast redeploy can be used"
            export vm_cleanup_needed="false"
            export clean_needed="false"
            export cleanup_reason="successful_same_topology"
            return 1  # No cleanup needed  
            ;;
        *)
            echo "Same topology but unknown deployment status (${previous_status:-empty})"
            echo "Using clean deployment for safety"
            export vm_cleanup_needed="false"
            export clean_needed="true"
            export cleanup_reason="unknown_status"
            return 0  # Clean needed for safety
            ;;
    esac
}

# Note: Cluster state is now managed by the Ansible playbook

# Check if the instance exists and get its ID
if [[ ! -f "${NODE_DIR}/aws-instance-id" ]]; then
    echo "Error: No instance found. Please run 'make deploy' first."
    exit 1
fi

INSTANCE_ID=$(cat "${NODE_DIR}/aws-instance-id")
echo "Redeploying OpenShift cluster on instance ${INSTANCE_ID}..."

# Check current instance state
INSTANCE_STATE=$(aws --region "${REGION}" ec2 describe-instances --instance-ids "${INSTANCE_ID}" --query 'Reservations[0].Instances[0].State.Name' --output text --no-cli-pager)

if [[ "${INSTANCE_STATE}" != "running" ]]; then
    echo "Error: Instance is not running (state: ${INSTANCE_STATE})"
    echo "Cannot redeploy cluster on a stopped instance."
    exit 1
fi

# Get the instance IP
HOST_PUBLIC_IP=$(aws --region "${REGION}" ec2 describe-instances --instance-ids "${INSTANCE_ID}" --query 'Reservations[0].Instances[0].PublicIpAddress' --output text --no-cli-pager)

if [[ "${HOST_PUBLIC_IP}" == "null" || "${HOST_PUBLIC_IP}" == "" ]]; then
    echo "Error: Could not determine instance public IP"
    exit 1
fi

echo "Connecting to instance at ${HOST_PUBLIC_IP}..."

# Update SSH config
echo "Updating SSH config for aws-hypervisor..."
(cd "${DEPLOY_DIR}/aws-hypervisor" && go run main.go -k aws-hypervisor -h "$HOST_PUBLIC_IP")

# Interactive mode selection
echo ""
echo "Select deployment mode:"
echo "1) arbiter"
echo "2) fencing"
read -rp "Enter choice (1-2): " choice

case $choice in
    1) topology="arbiter" ;;
    2) topology="fencing" ;;
    *) echo "Invalid choice"; exit 1 ;;
esac

echo "Selected topology: $topology"

# Check deployment requirements
if check_vm_infrastructure_change "$topology"; then
    # Some form of cleanup is needed
    echo ""
    case "$cleanup_reason" in
        "topology_change")
            echo "=================================="
            echo "COMPLETE REBUILD: Cluster type change detected"
            echo "This will run 'make realclean' followed by full installation"
            echo "This ensures completely clean state but will take significantly longer"
            echo "=================================="
            ;;
        "incomplete_deployment"|"unknown_status")
            echo "=================================="
            echo "CLEAN DEPLOYMENT: Previous deployment incomplete or unknown status"
            echo "This will run 'make clean' to clear incomplete state"
            echo "Then perform fresh deployment (faster than complete rebuild)"
            echo "=================================="
            ;;
    esac
    echo ""
else
    # No cleanup needed
    echo ""
    echo "=================================="
    echo "FAST REDEPLOY: Same topology, successful previous deployment"
    echo "This will use 'make redeploy' for fastest deployment"
    echo "Preserves cached data for optimal speed"
    echo "=================================="
    echo ""
fi

# Navigate to the openshift-clusters directory and run the redeploy playbook
echo "Running Ansible redeploy playbook..."
cd "${DEPLOY_DIR}/openshift-clusters"

# Check if inventory.ini exists
if [[ ! -f "inventory.ini" ]]; then
    echo "Error: inventory.ini not found in ${DEPLOY_DIR}/openshift-clusters/"
    echo "Please ensure the inventory file is properly configured."
    exit 1
fi

# Run the redeploy playbook
echo "=================================="
echo "Starting OpenShift cluster deployment using Ansible"
echo "=================================="
echo "This will:"
if [[ "$vm_cleanup_needed" == "true" ]]; then
    echo "1. Complete cleanup (make realclean)"
    echo "2. Full installation from scratch (make all)"
    echo "3. This is slower but ensures clean state for new topology"
elif [[ "$clean_needed" == "true" ]]; then
    echo "1. Clean incomplete deployment state (make clean)"
    echo "2. Fresh deployment (make all)"
    echo "3. This recovers from incomplete state"
else
    echo "1. Fast redeploy (make redeploy) for same topology"
    echo "2. This preserves cached data for faster deployment"
fi
echo "=================================="

# Call ansible in non-interactive mode with all parameters pre-determined
# Convert method to lowercase for ansible (state file stores uppercase)
# Uses tr instead of ${var,,} for bash 3.2 (macOS) compatibility.
ansible-playbook redeploy.yml -i inventory.ini \
    --extra-vars "topology=${topology}" \
    --extra-vars "method=$(echo "${current_installation_method}" | tr '[:upper:]' '[:lower:]')" \
    --extra-vars "vm_cleanup_needed=${vm_cleanup_needed}" \
    --extra-vars "clean_needed=${clean_needed:-false}" \
    --extra-vars "cleanup_reason=${cleanup_reason}" \
    --extra-vars "interactive_mode=false" \
    --timeout=30 \
    --forks=10

echo "=================================="
echo "✓ OpenShift cluster redeploy completed successfully!"
echo "=================================="
print_proxy_instructions
