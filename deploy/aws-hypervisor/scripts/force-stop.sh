#!/usr/bin/env bash

SCRIPT_DIR=$(dirname "$0")
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/../../common.sh"

set -o nounset
set -o errexit
set -o pipefail

# Configuration for wait retries (shorter for force stop)
FORCE_STOP_WAIT_RETRIES=${FORCE_STOP_WAIT_RETRIES:-2}

# Function to wait for instance to stop with retry logic
wait_for_instance_stopped() {
    local instance_id="$1"
    local attempt=1
    
    echo "Waiting for instance to stop (max ${FORCE_STOP_WAIT_RETRIES} attempts)..."
    
    while [[ $attempt -le $FORCE_STOP_WAIT_RETRIES ]]; do
        echo "Attempt ${attempt}/${FORCE_STOP_WAIT_RETRIES}..."
        
        set +e  # Allow this command to fail
        aws --region "${REGION}" ec2 wait instance-stopped --instance-ids "${instance_id}" --no-cli-pager
        wait_result=$?
        set -e
        
        if [[ $wait_result -eq 0 ]]; then
            echo "Instance stopped successfully."
            return 0
        fi
        
        if [[ $attempt -lt $FORCE_STOP_WAIT_RETRIES ]]; then
            echo "Wait command timed out. Retrying..."
        fi
        
        attempt=$((attempt + 1))
    done
    
    echo "Warning: Instance may not have stopped cleanly after ${FORCE_STOP_WAIT_RETRIES} attempts"
    echo "Check instance status with: make status"
    return 1
}

# Check if the instance exists and get its ID
node_dir="$(get_node_dir)"
if [[ ! -f "${node_dir}/aws-instance-id" ]]; then
    echo "Error: No instance found. Please run 'make deploy' first."
    exit 1
fi

INSTANCE_ID=$(cat "${node_dir}/aws-instance-id")

# Get current instance state
INSTANCE_STATE=$(aws --region "${REGION}" ec2 describe-instances --instance-ids "${INSTANCE_ID}" --query 'Reservations[0].Instances[0].State.Name' --output text --no-cli-pager)
echo "Current instance state: ${INSTANCE_STATE}"

echo "==================== FORCE STOP WARNING ===================="
echo "This will immediately stop the EC2 instance ${INSTANCE_ID}"
echo "WITHOUT checking for running OpenShift clusters or other services."
echo ""
echo "This operation:"
echo "- Will forcibly shutdown any running virtual machines"
echo "- May cause data loss if services are not properly stopped"
echo "- Will not preserve cluster state"
echo ""
echo "Use 'make stop' for graceful shutdown with cluster preservation."
echo "=============================================================="
echo ""

case "${INSTANCE_STATE}" in
    "stopped")
        echo "Instance is already stopped."
        ;;
    "running"|"stopping"|"pending")
        echo "Force stopping instance ${INSTANCE_ID}..."
        aws --region "${REGION}" ec2 stop-instances --instance-ids "${INSTANCE_ID}" --force --no-cli-pager
        wait_for_instance_stopped "${INSTANCE_ID}" || true
        ;;
    *)
        echo "Error: Instance is in an unexpected state: ${INSTANCE_STATE}"
        echo "Current state does not allow stop operation."
        exit 1
        ;;
esac

# Final state check
FINAL_STATE=$(aws --region "${REGION}" ec2 describe-instances --instance-ids "${INSTANCE_ID}" --query 'Reservations[0].Instances[0].State.Name' --output text --no-cli-pager)
echo "Final instance state: ${FINAL_STATE}"

if [[ "${FINAL_STATE}" == "stopped" ]]; then
    echo "Instance ${INSTANCE_ID} has been force stopped."
else
    echo "Warning: Instance may not be fully stopped. Current state: ${FINAL_STATE}"
fi

echo ""
echo "To restart the instance: make start"
echo "To redeploy OpenShift cluster: make redeploy-cluster" 