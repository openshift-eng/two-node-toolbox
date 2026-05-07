#!/bin/bash

# Get the directory where this script is located
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEPLOY_DIR="$(cd "${SCRIPT_DIR}/../../" && pwd)"

# Source the instance.env file with absolute path
# shellcheck source=/dev/null
source "${DEPLOY_DIR}/aws-hypervisor/instance.env"

# Resolve SHARED_DIR to absolute path if it's relative
if [[ "${SHARED_DIR}" != /* ]]; then
    export SHARED_DIR="${DEPLOY_DIR}/aws-hypervisor/${SHARED_DIR}"
fi

set -o nounset
set -o errexit
set -o pipefail

# Check if the instance exists and get its ID
if [[ ! -f "${SHARED_DIR}/aws-instance-id" ]]; then
    echo "Error: No instance found. Please run 'make deploy' first."
    exit 1
fi

INSTANCE_ID=$(cat "${SHARED_DIR}/aws-instance-id")
echo "Shutting down OpenShift cluster VMs on instance ${INSTANCE_ID}..."

# Check current instance state
INSTANCE_STATE=$(aws --region "${REGION}" ec2 describe-instances --instance-ids "${INSTANCE_ID}" --query 'Reservations[0].Instances[0].State.Name' --output text --no-cli-pager)

if [[ "${INSTANCE_STATE}" != "running" ]]; then
    echo "Error: Instance is not running (state: ${INSTANCE_STATE})"
    echo "Cannot shutdown cluster on a stopped instance."
    exit 1
fi

# Get the instance IP
HOST_PUBLIC_IP=$(aws --region "${REGION}" ec2 describe-instances --instance-ids "${INSTANCE_ID}" --query 'Reservations[0].Instances[0].PublicIpAddress' --output text --no-cli-pager)

if [[ "${HOST_PUBLIC_IP}" == "null" || "${HOST_PUBLIC_IP}" == "" ]]; then
    echo "Error: Could not determine instance public IP"
    exit 1
fi

echo "Connecting to instance at ${HOST_PUBLIC_IP}..."

# Check if dev-scripts directory exists
set +e  # Allow commands to fail
ssh -o ConnectTimeout=10 "$(cat "${SHARED_DIR}/ssh_user")@${HOST_PUBLIC_IP}" "test -d ~/openshift-metal3" 2>/dev/null
DEV_SCRIPTS_EXISTS=$?
set -e

if [[ ${DEV_SCRIPTS_EXISTS} -ne 0 ]]; then
    echo "No dev-scripts directory found on the instance."
    echo "No OpenShift cluster to shutdown."
    exit 0
fi

echo "Found dev-scripts directory. Performing orderly shutdown of cluster VMs..."

# Refresh certificates before shutdown to maximize validity window on next startup
REPO_ROOT="$(cd "${SCRIPT_DIR}/../../.." && pwd)"
REFRESH_CERTS_SCRIPT="${REPO_ROOT}/helpers/refresh-certificates.sh"
PROXY_ENV="${SCRIPT_DIR}/../proxy.env"

if [[ -x "${REFRESH_CERTS_SCRIPT}" && -f "${PROXY_ENV}" ]]; then
    echo ""
    echo "Refreshing short-lived certificates before shutdown..."
    "${REFRESH_CERTS_SCRIPT}" --proxy-env "${PROXY_ENV}" || echo "Warning: Certificate refresh failed. Proceeding with shutdown."
    echo ""
else
    echo "Skipping certificate refresh (script or proxy.env not found)."
fi

# Perform orderly shutdown of the cluster VMs
ssh "$(cat "${SHARED_DIR}/ssh_user")@${HOST_PUBLIC_IP}" << 'EOF'
    set -e
    cd ~/openshift-metal3/dev-scripts
    
    # Source the config to get cluster name
    source common.sh
    
    echo "Shutting down OpenShift cluster VMs for cluster: ${CLUSTER_NAME}"
    
    # Get all VMs that belong to this cluster
    VMS=$(sudo virsh list --all --name | grep "^${CLUSTER_NAME}" || true)
    
    if [[ -z "${VMS}" ]]; then
        echo "No cluster VMs found to shutdown."
        exit 0
    fi
    
    # Save the list of VMs for later startup
    echo "${VMS}" > ~/cluster-vms.txt
    echo "Saved VM list to ~/cluster-vms.txt for later startup"
    
    # Shutdown each VM gracefully
    for vm in ${VMS}; do
        VM_STATE=$(sudo virsh domstate "${vm}" 2>/dev/null || echo "undefined")
        echo "VM ${vm} state: ${VM_STATE}"
        
        if [[ "${VM_STATE}" == "running" ]]; then
            echo "Shutting down VM: ${vm}"
            # Try graceful shutdown first
            timeout 60 sudo virsh shutdown "${vm}" || echo "Graceful shutdown failed for ${vm}"
            
            # Wait up to 2 minutes for graceful shutdown
            echo "Waiting for ${vm} to shutdown gracefully..."
            for i in {1..24}; do
                VM_STATE=$(sudo virsh domstate "${vm}" 2>/dev/null || echo "undefined")
                if [[ "${VM_STATE}" == "shut off" ]]; then
                    echo "VM ${vm} shutdown gracefully"
                    break
                fi
                sleep 5
            done
            
            # If still running, force shutdown
            VM_STATE=$(sudo virsh domstate "${vm}" 2>/dev/null || echo "undefined")
            if [[ "${VM_STATE}" == "running" ]]; then
                echo "Forcing shutdown of VM: ${vm}"
                sudo virsh destroy "${vm}" || echo "Failed to force shutdown ${vm}"
            fi
        elif [[ "${VM_STATE}" == "shut off" ]]; then
            echo "VM ${vm} is already shut off"
        else
            echo "VM ${vm} is in state ${VM_STATE}, attempting shutdown..."
            sudo virsh shutdown "${vm}" || sudo virsh destroy "${vm}" || echo "Failed to shutdown ${vm}"
        fi
    done
    
    echo ""
    echo "Cluster VMs shutdown completed!"
    echo "VM list saved to ~/cluster-vms.txt"
    echo ""
    echo "To start the cluster later, run the 'startup-cluster.sh' script"
    echo "You can now safely stop the instance with 'make stop'"
EOF

echo "OpenShift cluster VMs shutdown completed!"
echo "The instance is now safe to stop with 'make stop'"
echo "When you restart the instance, use 'make startup-cluster' to start the cluster" 