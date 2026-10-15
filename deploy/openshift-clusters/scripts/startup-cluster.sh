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

# Check if the instance exists and get its ID
if [[ ! -f "${NODE_DIR}/aws-instance-id" ]]; then
    echo "Error: No instance found. Please run 'make deploy' first."
    exit 1
fi

INSTANCE_ID=$(cat "${NODE_DIR}/aws-instance-id")
echo "Starting up OpenShift cluster VMs on instance ${INSTANCE_ID}..."

# Check cluster topology from state file
CLUSTER_STATE_FILE="$(get_shared_dir)/cluster-vm-state.json"
CLUSTER_TOPOLOGY=""
if [[ -f "${CLUSTER_STATE_FILE}" ]]; then
    CLUSTER_TOPOLOGY=$(grep -o '"topology":[[:space:]]*"[^"]*"' "${CLUSTER_STATE_FILE}" | cut -d'"' -f4 2>/dev/null || echo "")
    echo "Detected cluster topology: ${CLUSTER_TOPOLOGY:-unknown}"
fi

# Check current instance state
INSTANCE_STATE=$(aws --region "${REGION}" ec2 describe-instances --instance-ids "${INSTANCE_ID}" --query 'Reservations[0].Instances[0].State.Name' --output text --no-cli-pager)

if [[ "${INSTANCE_STATE}" != "running" ]]; then
    echo "Error: Instance is not running (state: ${INSTANCE_STATE})"
    echo "Cannot start cluster on a stopped instance."
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
ssh -o ConnectTimeout=10 "$(cat "${NODE_DIR}/ssh_user")@${HOST_PUBLIC_IP}" "test -d ~/openshift-metal3" 2>/dev/null
DEV_SCRIPTS_EXISTS=$?
set -e

if [[ ${DEV_SCRIPTS_EXISTS} -ne 0 ]]; then
    echo "No dev-scripts directory found on the instance."
    echo "No OpenShift cluster to start."
    exit 0
fi

echo "Found dev-scripts directory. Starting up OpenShift cluster VMs..."

# Start the cluster VMs remotely
ssh "$(cat "${NODE_DIR}/ssh_user")@${HOST_PUBLIC_IP}" << 'EOF'
    set -e
    cd ~/openshift-metal3/dev-scripts
    
    # Check if we have a cluster VMs list from shutdown
    if [[ ! -f ~/cluster-vms.txt ]]; then
        echo "No cluster VMs list found (~/cluster-vms.txt)"
        echo "Either no VMs were shut down with shutdown-cluster.sh, or they were managed manually"
        echo "Checking for any existing cluster VMs..."
        
        # Source the config to get cluster name
        source common.sh
        
        # Get all VMs that belong to this cluster
        VMS=$(sudo virsh list --all --name | grep "^${CLUSTER_NAME}" || true)
        
        if [[ -z "${VMS}" ]]; then
            echo "No cluster VMs found."
            echo "You may need to deploy a new cluster."
            exit 0
        fi
        
        echo "Found existing cluster VMs: ${VMS}"
    else
        # Read the cluster VMs list
        VMS=$(cat ~/cluster-vms.txt)
        echo "Found cluster VMs list: ${VMS}"
    fi
    
    # Ensure libvirt services are running
    echo "Ensuring libvirt services are running..."
    sudo systemctl start libvirtd || true
    sudo systemctl start virtlogd || true
    
    # Start the podman proxy container first
    echo "Starting podman proxy container..."
    if podman ps -a --filter name=external-squid --format "{{.Names}}" | grep -q external-squid; then
        CONTAINER_STATUS=$(podman ps -a --filter name=external-squid --format "{{.Status}}")
        echo "Found proxy container with status: ${CONTAINER_STATUS}"
        
        if [[ "${CONTAINER_STATUS}" =~ ^Up ]]; then
            echo "Proxy container is already running"
        else
            echo "Starting existing proxy container..."
            podman start external-squid || echo "Failed to start proxy container"
        fi
    else
        echo "No proxy container found. It may need to be created during cluster deployment."
    fi
    
    # Wait a moment for proxy to initialize
    sleep 5
    
    # Start each VM
    echo "Starting cluster VMs..."
    for vm in ${VMS}; do
        VM_STATE=$(sudo virsh domstate "${vm}" 2>/dev/null || echo "undefined")
        echo "VM ${vm} state: ${VM_STATE}"
        
        if [[ "${VM_STATE}" == "shut off" ]]; then
            echo "Starting VM: ${vm}"
            sudo virsh start "${vm}" || echo "Failed to start ${vm}"
        elif [[ "${VM_STATE}" == "running" ]]; then
            echo "VM ${vm} is already running"
        elif [[ "${VM_STATE}" == "paused" ]]; then
            echo "VM ${vm} is paused, resuming..."
            sudo virsh resume "${vm}" || echo "Failed to resume ${vm}"
        else
            echo "VM ${vm} is in state ${VM_STATE}, attempting to start..."
            sudo virsh start "${vm}" || echo "Failed to start ${vm}"
        fi
    done
    
    echo ""
    echo "Waiting for VMs to initialize..."
    sleep 30
    
    # Check proxy container final status
    echo "Checking proxy container final status..."
    PROXY_STATUS=$(podman ps --filter name=external-squid --format "{{.Status}}" 2>/dev/null || echo "not running")
    if [[ "${PROXY_STATUS}" =~ ^Up ]]; then
        echo "Proxy container is running: ${PROXY_STATUS}"
    else
        echo "Warning: Proxy container may not be running properly: ${PROXY_STATUS}"
    fi
    
    echo ""
    echo "Cluster VMs startup completed!"
    echo "The OpenShift cluster VMs are now running."
    echo ""
    echo "You can check the cluster status as usual, depending on your setup."
    echo "It might take a few minutes for the cluster to be fully ready."

    # Clean up the cluster VMs list
    rm -f ~/cluster-vms.txt
EOF

# Start sushy-tools BMC simulator for fencing topology
if [[ "${CLUSTER_TOPOLOGY}" == "fencing" ]]; then
    echo ""
    echo "Fencing topology detected. Ensuring sushy-tools BMC simulator is running..."

    ssh "$(cat "${NODE_DIR}/ssh_user")@${HOST_PUBLIC_IP}" << 'EOF'
        # Check if sushy-tools container exists (dev-scripts deployment)
        if sudo podman container exists sushy-tools 2>/dev/null; then
            CONTAINER_STATUS=$(sudo podman inspect sushy-tools --format '{{.State.Status}}' 2>/dev/null || echo "unknown")
            echo "sushy-tools container status: ${CONTAINER_STATUS}"

            if [[ "${CONTAINER_STATUS}" == "running" ]]; then
                echo "sushy-tools BMC simulator is already running"
            else
                echo "Starting sushy-tools container..."
                sudo podman start sushy-tools

                # Wait and verify
                sleep 2
                CONTAINER_STATUS=$(sudo podman inspect sushy-tools --format '{{.State.Status}}' 2>/dev/null || echo "unknown")
                if [[ "${CONTAINER_STATUS}" == "running" ]]; then
                    echo "sushy-tools container started successfully"
                else
                    echo "Warning: Failed to start sushy-tools container"
                    echo "STONITH fencing may not work properly"
                    echo "You can try manually: sudo podman start sushy-tools"
                fi
            fi
        # Fallback: check for ksushy user service (kcli deployment)
        elif systemctl --user list-unit-files ksushy.service &>/dev/null; then
            KSUSHY_STATUS=$(systemctl --user is-active ksushy.service 2>/dev/null || echo "inactive")

            if [[ "${KSUSHY_STATUS}" == "active" ]]; then
                echo "ksushy BMC simulator is already running"
            else
                echo "Starting ksushy BMC simulator..."
                systemctl --user start ksushy.service

                sleep 2
                if systemctl --user is-active ksushy.service &>/dev/null; then
                    echo "ksushy BMC simulator started successfully"
                else
                    echo "Warning: Failed to start ksushy service"
                    echo "STONITH fencing may not work properly"
                fi
            fi
        else
            echo "Warning: No BMC simulator found (sushy-tools container or ksushy service)"
            echo "STONITH fencing may not work properly"
        fi
EOF
fi

echo ""
echo "=================================="
echo "OpenShift cluster startup completed successfully!"
echo "=================================="
print_proxy_instructions 