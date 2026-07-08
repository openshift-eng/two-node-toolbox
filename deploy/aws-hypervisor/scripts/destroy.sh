#!/bin/bash

SCRIPT_DIR=$(dirname "$0")
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/common.sh"

set -o nounset
set -o errexit
set -o pipefail

shared_dir="$(get_shared_dir)"
node_dir="$(get_node_dir)"
public_address_file="${node_dir}/public_address"
ssh_user_file="${node_dir}/ssh_user"
network_stack_name_file="${shared_dir}/network_stack_name"
NETWORK_STACK_NAME="${STACK_NAME}-network"

# Check if we have a deployed instance
if [[ ! -f "$public_address_file" ]] || [[ ! -f "$ssh_user_file" ]]; then
    echo "No deployed instance found (missing instance data files)."
    echo "Checking if CloudFormation stacks exist..."

    compute_exists=false
    network_exists=false
    if aws --region "$REGION" cloudformation describe-stacks --stack-name "${STACK_NAME}" &>/dev/null; then
        compute_exists=true
    fi
    if [[ -f "$network_stack_name_file" ]]; then
        NETWORK_STACK_NAME=$(cat "$network_stack_name_file")
    fi
    if aws --region "$REGION" cloudformation describe-stacks --stack-name "${NETWORK_STACK_NAME}" &>/dev/null; then
        network_exists=true
    fi

    if [[ "$compute_exists" == "false" ]] && [[ "$network_exists" == "false" ]]; then
        echo "No CloudFormation stacks found. Nothing to destroy."
        exit 0
    fi
else
    echo "Found deployed instance, proceeding with cleanup..."

    instance_ip=$(cat "$public_address_file")
    host=$(cat "$ssh_user_file")
    ssh_host_ip="$host@$instance_ip"

    echo "Unregistering subscription manager on instance..."
    ssh "$ssh_host_ip" "sudo subscription-manager unregister" || echo "Warning: Failed to unregister subscription manager (instance may be unreachable or not registered)"

    if [[ -f "$network_stack_name_file" ]]; then
        NETWORK_STACK_NAME=$(cat "$network_stack_name_file")
    fi
fi

# Cancel capacity reservation if it exists
reservation_file="${node_dir}/capacity-reservation-id"
if [[ -f "${reservation_file}" ]]; then
    reservation_id=$(cat "${reservation_file}")
    if [[ -n "${reservation_id}" && "${reservation_id}" != "null" ]]; then
        cancel_capacity_reservation "${reservation_id}" "${REGION}"
    fi
    rm -f "${reservation_file}"
    rm -f "${node_dir}/availability-zone"
fi

# Cancel persistent spot request if the instance is a spot instance
instance_id_file="${instance_data_dir}/aws-instance-id"
if [[ -f "${instance_id_file}" ]]; then
    instance_id=$(cat "${instance_id_file}")
    spot_request_id=$(aws --region "${REGION}" ec2 describe-instances \
        --instance-ids "${instance_id}" \
        --query 'Reservations[0].Instances[0].SpotInstanceRequestId' \
        --output text --no-cli-pager 2>/dev/null || echo "")

    if [[ -n "${spot_request_id}" && "${spot_request_id}" != "None" && "${spot_request_id}" != "null" ]]; then
        msg_info "Canceling persistent spot request ${spot_request_id}..."
        aws --region "${REGION}" ec2 cancel-spot-instance-requests \
            --spot-instance-request-ids "${spot_request_id}" \
            --no-cli-pager >/dev/null 2>&1 || msg_warning "Failed to cancel spot request (may already be canceled)"
    fi
fi

# Delete compute stack first (CF prevents deleting network while its exports are imported)
if aws --region "$REGION" cloudformation describe-stacks --stack-name "${STACK_NAME}" &>/dev/null; then
    echo "Deleting compute stack '${STACK_NAME}'..."
    aws --region "$REGION" cloudformation delete-stack --stack-name "${STACK_NAME}"
    echo "Waiting for compute stack deletion..."
    if ! { aws --region "$REGION" cloudformation wait stack-delete-complete --stack-name "${STACK_NAME}" & wait "$!"; }; then
        echo "ERROR: Compute stack deletion failed or timed out." >&2
        echo "Network stack '${NETWORK_STACK_NAME}' was NOT deleted." >&2
        echo "Check the AWS CloudFormation console for details." >&2
        exit 1
    fi
fi

# Delete network stack
if aws --region "$REGION" cloudformation describe-stacks --stack-name "${NETWORK_STACK_NAME}" &>/dev/null; then
    echo "Deleting network stack '${NETWORK_STACK_NAME}'..."
    aws --region "$REGION" cloudformation delete-stack --stack-name "${NETWORK_STACK_NAME}"
    echo "Waiting for network stack deletion..."
    aws --region "$REGION" cloudformation wait stack-delete-complete --stack-name "${NETWORK_STACK_NAME}" &
    wait "$!"
fi

# Clean up instance data directory
if [[ -d "$shared_dir" ]]; then
    echo "Cleaning up instance data..."
    rm -rf "${shared_dir:?}/"*
    echo "Stacks deleted successfully." > "${shared_dir}/.done"
fi

echo "Destroy operation completed successfully."
