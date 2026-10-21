#!/usr/bin/env bash

# Clean spoke cluster resources (VMs, network, auth) created by assisted installer
# This is the counterpart to deploy-fencing-assisted.sh

SCRIPT_DIR=$(dirname "$0")
DEPLOY_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"

# shellcheck source=/dev/null
source "${DEPLOY_DIR}/common.sh"

set -o nounset
set -o errexit
set -o pipefail

NODE_DIR="$(get_node_dir)"

# Check if instance data exists
if [[ ! -f "${NODE_DIR}/aws-instance-id" ]]; then
    echo "Error: No instance found. Please run 'make deploy' first."
    exit 1
fi

# Parse spoke_cluster_name from vars/assisted.yml
SPOKE_CLUSTER_NAME="spoke-tnf"
if [[ -f "${DEPLOY_DIR}/openshift-clusters/vars/assisted.yml" ]]; then
    PARSED_NAME=$(grep '^spoke_cluster_name:' "${DEPLOY_DIR}/openshift-clusters/vars/assisted.yml" | awk '{print $2}' | tr -d '"' | tr -d "'" || true)
    if [[ -n "${PARSED_NAME}" ]]; then
        SPOKE_CLUSTER_NAME="${PARSED_NAME}"
    fi
fi

if [[ ! "${SPOKE_CLUSTER_NAME}" =~ ^[a-z0-9]([a-z0-9-]*[a-z0-9])?$ ]]; then
    echo "Error: Invalid spoke_cluster_name '${SPOKE_CLUSTER_NAME}'."
    exit 1
fi

# Derive the libvirt network bridge name from the cluster name
SPOKE_NETWORK="${SPOKE_CLUSTER_NAME}"

# Get SSH connection info
INSTANCE_IP=$(cat "${NODE_DIR}/public_address" 2>/dev/null || echo "")
SSH_USER=$(cat "${NODE_DIR}/ssh_user" 2>/dev/null || echo "ec2-user")

if [[ -z "${INSTANCE_IP}" ]]; then
    echo "Error: Could not determine instance IP."
    exit 1
fi

SSH_KEY_OPT=""
if [[ -n "${SSH_PUBLIC_KEY:-}" ]]; then
    SSH_KEY_OPT="-i ${SSH_PUBLIC_KEY%.pub}"
fi

SSH_CMD="ssh ${SSH_KEY_OPT} -o ConnectTimeout=10 -o StrictHostKeyChecking=no ${SSH_USER}@${INSTANCE_IP}"

echo "Cleaning spoke cluster '${SPOKE_CLUSTER_NAME}' resources..."

if ! ${SSH_CMD} "true" >/dev/null 2>&1; then
    echo "Error: Unable to connect to ${SSH_USER}@${INSTANCE_IP}."
    exit 1
fi

# Find and destroy spoke VMs
echo ""
echo "--- Removing spoke VMs ---"
SPOKE_VMS=$(${SSH_CMD} "sudo virsh list --all --name 2>/dev/null | grep '^${SPOKE_CLUSTER_NAME}-'" 2>/dev/null || true)
if [[ -n "${SPOKE_VMS}" ]]; then
    for vm in ${SPOKE_VMS}; do
        echo "Destroying VM: ${vm}"
        ${SSH_CMD} "sudo virsh destroy '${vm}' 2>/dev/null; sudo virsh undefine '${vm}' --remove-all-storage --nvram 2>/dev/null" || true
    done
else
    echo "No spoke VMs found."
fi

# Remove spoke network
echo ""
echo "--- Removing spoke network ---"
NET_EXISTS=$(${SSH_CMD} "sudo virsh net-list --all --name 2>/dev/null | grep '^${SPOKE_NETWORK}$'" 2>/dev/null || true)
if [[ -n "${NET_EXISTS}" ]]; then
    echo "Removing network: ${SPOKE_NETWORK}"
    ${SSH_CMD} "sudo virsh net-destroy '${SPOKE_NETWORK}' 2>/dev/null; sudo virsh net-undefine '${SPOKE_NETWORK}' 2>/dev/null" || true
else
    echo "No spoke network found."
fi

# Remove spoke auth directory
echo ""
echo "--- Removing spoke credentials ---"
${SSH_CMD} "rm -rf ~/${SPOKE_CLUSTER_NAME}" 2>/dev/null || true
echo "Removed ~/${SPOKE_CLUSTER_NAME}"

# Remove any stale symlinks in libvirt images
echo ""
echo "--- Cleaning stale symlinks ---"
${SSH_CMD} "sudo find /var/lib/libvirt/images/ -name '${SPOKE_CLUSTER_NAME}-*' -type l -delete 2>/dev/null" || true

echo ""
echo "✓ Spoke cluster '${SPOKE_CLUSTER_NAME}' cleanup completed."
