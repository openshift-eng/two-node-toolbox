#!/bin/bash

SCRIPT_DIR=$(dirname "$0")
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/../../common.sh"

set -o nounset
set -o errexit
set -o pipefail

# Retry only capacity shortages. Keep AWS diagnostics and the original exit code.
# Make three total start attempts, 60 seconds apart; AWS CLI retries are separate.
function start_instance_with_retries() {
    local instance_id="$1"
    local region="$2"
    local attempt=1
    local start_output start_status

    while true; do
        echo "Starting instance (attempt ${attempt}/3)..."
        if start_output=$(aws --region "${region}" ec2 start-instances \
            --instance-ids "${instance_id}" --no-cli-pager 2>&1); then
            return 0
        else
            start_status=$?
        fi
        printf '%s\n' "${start_output}" >&2

        if [[ ${start_output} != *"InsufficientInstanceCapacity"* ]]; then
            return "${start_status}"
        fi
        if (( attempt >= 3 )); then
            echo "Error: Capacity unavailable for ${instance_id} in ${region} after ${attempt} start attempts." >&2
            echo "Retry 'make start' later. This instance must restart in its existing Availability Zone." >&2
            echo "For a new deployment, consider another Availability Zone or region; changing REGION does not move this instance." >&2
            echo "Instance type offerings indicate support, not current free capacity. See deploy/aws-hypervisor/README.md." >&2
            return "${start_status}"
        fi

        echo "Insufficient instance capacity; retrying in 60 seconds..." >&2
        sleep 60
        attempt=$((attempt + 1))
    done
}

# Ensure instance uses open capacity reservation preference before starting.
# The capacity reservation from create time is ephemeral (auto-expires after ~1 hour),
# so a stopped instance must not target a specific reservation that no longer exists.
function ensure_open_capacity_preference() {
    local instance_id="$1"
    local region="$2"

    local current_pref
    current_pref=$(aws --region "${region}" ec2 describe-instances \
        --instance-ids "${instance_id}" \
        --query 'Reservations[0].Instances[0].CapacityReservationSpecification.CapacityReservationPreference' \
        --output text --no-cli-pager || echo "query-failed")

    if [[ "${current_pref}" != "open" ]]; then
        msg_info "Switching capacity reservation preference to 'open'..."
        aws --region "${region}" ec2 modify-instance-capacity-reservation-attributes \
            --instance-id "${instance_id}" \
            --capacity-reservation-specification "CapacityReservationPreference=open" \
            --no-cli-pager > /dev/null
    fi
}

# Check if the instance exists and get its ID
node_dir="$(get_node_dir)"
if [[ ! -f "${node_dir}/aws-instance-id" ]]; then
    echo "Error: No instance found. Please run 'make deploy' first."
    exit 1
fi

INSTANCE_ID=$(cat "${node_dir}/aws-instance-id")
echo "Starting instance ${INSTANCE_ID}..."

# Check current instance state
# shellcheck disable=SC2153 # REGION is sourced from instance.env via common.sh, not a misspelling of local 'region'
INSTANCE_STATE=$(aws --region "${REGION}" ec2 describe-instances --instance-ids "${INSTANCE_ID}" --query 'Reservations[0].Instances[0].State.Name' --output text --no-cli-pager)
echo "Current instance state: ${INSTANCE_STATE}"

case "${INSTANCE_STATE}" in
    "running")
        echo "Instance is already running."
        ;;
    "stopped")
        ensure_open_capacity_preference "${INSTANCE_ID}" "${REGION}"
        start_instance_with_retries "${INSTANCE_ID}" "${REGION}"
        echo "Waiting for instance to start..."
        aws --region "${REGION}" ec2 wait instance-running --instance-ids "${INSTANCE_ID}" --no-cli-pager
        echo "Waiting for instance to be ready..."
        aws --region "${REGION}" ec2 wait instance-status-ok --instance-ids "${INSTANCE_ID}" --no-cli-pager
        ;;
    "stopping")
        echo "Instance is currently stopping. Waiting for it to stop completely..."
        aws --region "${REGION}" ec2 wait instance-stopped --instance-ids "${INSTANCE_ID}" --no-cli-pager
        ensure_open_capacity_preference "${INSTANCE_ID}" "${REGION}"
        start_instance_with_retries "${INSTANCE_ID}" "${REGION}"
        echo "Waiting for instance to start..."
        aws --region "${REGION}" ec2 wait instance-running --instance-ids "${INSTANCE_ID}" --no-cli-pager
        echo "Waiting for instance to be ready..."
        aws --region "${REGION}" ec2 wait instance-status-ok --instance-ids "${INSTANCE_ID}" --no-cli-pager
        ;;
    "pending")
        echo "Instance is already starting. Waiting for it to be ready..."
        aws --region "${REGION}" ec2 wait instance-running --instance-ids "${INSTANCE_ID}" --no-cli-pager
        echo "Waiting for instance to be ready..."
        aws --region "${REGION}" ec2 wait instance-status-ok --instance-ids "${INSTANCE_ID}" --no-cli-pager
        ;;
    *)
        echo "Error: Instance is in an unexpected state: ${INSTANCE_STATE}"
        exit 1
        ;;
esac

# Get the current public IP (it may have changed)
HOST_PUBLIC_IP=$(aws --region "${REGION}" ec2 describe-instances --instance-ids "${INSTANCE_ID}" --query 'Reservations[0].Instances[0].PublicIpAddress' --output text --no-cli-pager)
HOST_PRIVATE_IP=$(aws --region "${REGION}" ec2 describe-instances --instance-ids "${INSTANCE_ID}" --query 'Reservations[0].Instances[0].PrivateIpAddress' --output text --no-cli-pager)

echo "${HOST_PUBLIC_IP}" > "${node_dir}/public_address"
echo "${HOST_PRIVATE_IP}" > "${node_dir}/private_address"

echo "Instance ${INSTANCE_ID} is now running."
echo "Public IP: ${HOST_PUBLIC_IP}"
echo "Private IP: ${HOST_PRIVATE_IP}"

# Update SSH config
echo "Updating SSH config for aws-hypervisor..."
(cd "${SCRIPT_DIR}/.." && go run main.go -k aws-hypervisor -h "$HOST_PUBLIC_IP")

# Check and restart the proxy container for immediate proxy capabilities
echo "Checking proxy container status..."
set +e  # Allow commands to fail for proxy container checks
ssh -o ConnectTimeout=10 "$(cat "${node_dir}/ssh_user")@${HOST_PUBLIC_IP}" << 'EOF'
    echo "Checking external-squid proxy container..."
    
    # Check if the container exists and get its status
    CONTAINER_STATUS=$(podman ps -a --filter name=external-squid --format "{{.Status}}" 2>/dev/null || echo "not found")
    
    if [[ "${CONTAINER_STATUS}" == "not found" ]]; then
        echo "Proxy container not found - may not be deployed yet"
    elif [[ "${CONTAINER_STATUS}" =~ ^Up ]]; then
        echo "Proxy container is already running: ${CONTAINER_STATUS}"
    else
        echo "Proxy container exists but not running: ${CONTAINER_STATUS}"
        echo "Attempting to restart proxy container..."
        podman restart external-squid && echo "Proxy container restarted successfully" || echo "Failed to restart proxy container"
    fi
    
    # Give a moment for the container to start
    sleep 5
    
    # Final status check
    FINAL_STATUS=$(podman ps --filter name=external-squid --format "{{.Status}}" 2>/dev/null || echo "not running")
    if [[ "${FINAL_STATUS}" =~ ^Up ]]; then
        echo "Proxy container is now running and ready for use"
    else
        echo "Warning: Proxy container may not be running properly"
    fi
EOF
set -e  # Re-enable exit on error

echo "Instance started successfully!"
echo ""
echo "IMPORTANT: OpenShift cluster recovery options:"
echo ""
echo "If you previously shutdown your cluster:"
echo "  - Start up the cluster: make startup-cluster"
echo ""
echo "If you need to deploy a new cluster:"
echo "  - Clean and redeploy: make redeploy-cluster"
echo "  - For manual deployment: cd ../openshift-clusters && follow README"
