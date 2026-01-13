#!/bin/bash

SCRIPT_DIR=$(dirname "$0")
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/common.sh"

msg_info "Destroying deployment: ${DEPLOYMENT_ID}"

# Check if instance data directory exists and has the required files
instance_data_dir="${SCRIPT_DIR}/../${SHARED_DIR}"
public_address_file="${instance_data_dir}/public_address"
ssh_user_file="${instance_data_dir}/ssh_user"

# Check if we have a deployed instance
if [[ ! -f "$public_address_file" ]] || [[ ! -f "$ssh_user_file" ]]; then
    echo "No deployed instance found (missing instance data files)."
    echo "Checking if CloudFormation stack '${STACK_NAME}' exists..."
    
    # Check if the stack exists in CloudFormation
    if aws --region "$REGION" cloudformation describe-stacks --stack-name "${STACK_NAME}" &>/dev/null; then
        echo "Found CloudFormation stack '${STACK_NAME}' - proceeding with stack deletion only."
    else
        echo "No CloudFormation stack '${STACK_NAME}' found either."
        echo "Nothing to destroy."
        exit 0
    fi
else
    # Instance data exists, proceed with full cleanup
    echo "Found deployed instance, proceeding with cleanup..."
    
    instance_ip=$(cat "$public_address_file")
    host=$(cat "$ssh_user_file")
    ssh_host_ip="$host@$instance_ip"
    
    echo "Unregistering subscription manager on instance..."
    ssh "$ssh_host_ip" "sudo subscription-manager unregister" || echo "Warning: Failed to unregister subscription manager (instance may be unreachable or not registered)"
fi

# Delete the CloudFormation stack
echo "Deleting CloudFormation stack '${STACK_NAME}'..."
aws --region "$REGION" cloudformation delete-stack --stack-name "${STACK_NAME}"

echo "Waiting for stack $STACK_NAME to be deleted..."
aws --region "$REGION" cloudformation wait stack-delete-complete --stack-name "${STACK_NAME}" &
wait "$!"

# Clean up instance data directory
if [[ -d "$instance_data_dir" ]]; then
    echo "Cleaning up instance data..."
    rm -rf "${instance_data_dir:?}/"*
fi

echo "Stack ${STACK_NAME} has been successfully deleted." > "${instance_data_dir}/.done"
echo "Destroy operation completed successfully."