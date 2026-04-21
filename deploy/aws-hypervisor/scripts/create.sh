#!/bin/bash

SCRIPT_DIR=$(dirname "$0")
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/common.sh"

set -o nounset
set -o errexit
set -o pipefail

#Save stacks events and cleanup capacity reservation on failure
trap 'save_stack_events; cleanup_capacity_on_error' EXIT TERM INT

# Cleanup function for capacity reservation on error
function cleanup_capacity_on_error() {
    set +o errexit
    local reservation_file="${SCRIPT_DIR}/../${SHARED_DIR}/capacity-reservation-id"
    # Only cleanup if stack creation didn't complete successfully
    if [[ -f "${reservation_file}" && ! -f "${SCRIPT_DIR}/../${SHARED_DIR}/.stack-created" ]]; then
        local reservation_id
        reservation_id=$(cat "${reservation_file}")
        cancel_capacity_reservation "${reservation_id}" "${REGION}"
        rm -f "${reservation_file}"
        rm -f "${SCRIPT_DIR}/../${SHARED_DIR}/availability-zone"
    fi
    set -o errexit
}

mkdir -p "${SCRIPT_DIR}/../${SHARED_DIR}"

NETWORK_STACK_NAME="${STACK_NAME}-network"
TEMPLATES_DIR="${SCRIPT_DIR}/../templates"

function save_stack_events()
{
  set +o errexit
  aws --region "${REGION}" cloudformation describe-stack-events \
      --stack-name "${STACK_NAME}" --output json \
      > "${SCRIPT_DIR}/../${SHARED_DIR}/stack-events-${STACK_NAME}.json" 2>/dev/null
  aws --region "${REGION}" cloudformation describe-stack-events \
      --stack-name "${NETWORK_STACK_NAME}" --output json \
      > "${SCRIPT_DIR}/../${SHARED_DIR}/stack-events-${NETWORK_STACK_NAME}.json" 2>/dev/null
  set -o errexit
}

if [[ -n "${RHEL_HOST_AMI}" && -n "${RHEL_VERSION}" ]]; then
    echo "Warning: Both RHEL_HOST_AMI and RHEL_VERSION are set"
    echo "⌊ Choosing RHEL_HOST_AMI=$RHEL_HOST_AMI"
fi

if [[ -z "${RHEL_HOST_AMI}" ]]; then
    RHEL_HOST_AMI=$(get_rhel_ami)
fi

if [[ -z "${RHEL_HOST_AMI}" ]]; then
  echo "must supply an AMI to use for EC2 Instance"
  exit 1
fi

echo "ec2-user" > "${SCRIPT_DIR}/../${SHARED_DIR}/ssh_user"

echo -e "AMI ID: $RHEL_HOST_AMI"
echo -e "Machine Type: $EC2_INSTANCE_TYPE"
echo -e "Spot Instance: ${USE_SPOT_INSTANCE:-false}"

# Spot and capacity reservations are mutually exclusive
USE_SPOT="${USE_SPOT_INSTANCE:-false}"
if [[ "${USE_SPOT}" == "true" ]]; then
    msg_info "Spot instance requested - skipping capacity reservation (mutually exclusive)"
    ENABLE_CAPACITY_RESERVATION="false"
fi

# Create capacity reservation to validate and guarantee instance availability
CAPACITY_RESERVATION_ID=""
# Preserve user-provided AVAILABILITY_ZONE from instance.env
AVAILABILITY_ZONE="${AVAILABILITY_ZONE:-}"

if [[ "${ENABLE_CAPACITY_RESERVATION}" == "true" ]]; then
    if reservation_result=$(create_capacity_reservation "${EC2_INSTANCE_TYPE}" "${REGION}"); then
        CAPACITY_RESERVATION_ID=$(echo "${reservation_result}" | awk '{print $1}')
        AVAILABILITY_ZONE=$(echo "${reservation_result}" | awk '{print $2}')

        # Store for cleanup
        echo "${CAPACITY_RESERVATION_ID}" > "${SCRIPT_DIR}/../${SHARED_DIR}/capacity-reservation-id"
        echo "${AVAILABILITY_ZONE}" > "${SCRIPT_DIR}/../${SHARED_DIR}/availability-zone"

        msg_info "Capacity guaranteed in ${AVAILABILITY_ZONE}"
    else
        msg_err "Failed to reserve capacity. Aborting deployment."
        exit 1
    fi
else
    msg_info "Capacity reservation disabled, skipping pre-flight check"
fi

ec2Type="VirtualMachine"
if [[ "$EC2_INSTANCE_TYPE" =~ c[0-9]+[a-z]*.metal ]]; then
  ec2Type="MetalMachine"
fi

echo -e "==== Creating network stack ===="
echo "${STACK_NAME}" >> "${SCRIPT_DIR}/../${SHARED_DIR}/to_be_removed_cf_stack_list"
aws --region "$REGION" cloudformation create-stack \
    --stack-name "${NETWORK_STACK_NAME}" \
    --template-body "file://${TEMPLATES_DIR}/network-stack.yaml" \
    --capabilities CAPABILITY_NAMED_IAM \
    --no-cli-pager \
    --parameters \
        "ParameterKey=AvailabilityZone,ParameterValue=${AVAILABILITY_ZONE}"

echo "Waiting for network stack..."
aws --region "${REGION}" cloudformation wait stack-create-complete \
    --stack-name "${NETWORK_STACK_NAME}"

echo "${NETWORK_STACK_NAME}" > "${SCRIPT_DIR}/../${SHARED_DIR}/network_stack_name"

echo -e "==== Creating compute stack ===="
echo "${NETWORK_STACK_NAME}" >> "${SCRIPT_DIR}/../${SHARED_DIR}/to_be_removed_cf_stack_list"
aws --region "$REGION" cloudformation create-stack \
    --stack-name "${STACK_NAME}" \
    --template-body "file://${TEMPLATES_DIR}/compute-stack.yaml" \
    --capabilities CAPABILITY_NAMED_IAM \
    --no-cli-pager \
    --parameters \
        "ParameterKey=NetworkStackName,ParameterValue=${NETWORK_STACK_NAME}" \
        "ParameterKey=HostInstanceType,ParameterValue=${EC2_INSTANCE_TYPE}" \
        "ParameterKey=Machinename,ParameterValue=${STACK_NAME}" \
        "ParameterKey=AmiId,ParameterValue=${RHEL_HOST_AMI}" \
        "ParameterKey=EC2Type,ParameterValue=${ec2Type}" \
        "ParameterKey=PublicKeyString,ParameterValue=$(cat "${SSH_PUBLIC_KEY}")" \
        "ParameterKey=CapacityReservationId,ParameterValue=${CAPACITY_RESERVATION_ID}" \
        "ParameterKey=AvailabilityZone,ParameterValue=${AVAILABILITY_ZONE}" \
        "ParameterKey=UseSpot,ParameterValue=$( [[ "${USE_SPOT}" == "true" ]] && echo "Yes" || echo "No" )"

echo "Waiting for compute stack..."
aws --region "${REGION}" cloudformation wait stack-create-complete --stack-name "${STACK_NAME}"

echo "$STACK_NAME" > "${SCRIPT_DIR}/../${SHARED_DIR}/rhel_host_stack_name"
# shellcheck disable=SC2016
INSTANCE_ID="$(aws --region "${REGION}" cloudformation describe-stacks --stack-name "${STACK_NAME}" \
--query 'Stacks[].Outputs[?OutputKey == `InstanceId`].OutputValue' --output text)"
echo "Instance ${INSTANCE_ID}"
echo "${INSTANCE_ID}" > "${SCRIPT_DIR}/../${SHARED_DIR}/aws-instance-id"
# shellcheck disable=SC2016
HOST_PUBLIC_IP="$(aws --region "${REGION}" cloudformation describe-stacks --stack-name "${STACK_NAME}" \
  --query 'Stacks[].Outputs[?OutputKey == `PublicIp`].OutputValue' --output text)"
# shellcheck disable=SC2016
HOST_PRIVATE_IP="$(aws --region "${REGION}" cloudformation describe-stacks --stack-name "${STACK_NAME}" \
  --query 'Stacks[].Outputs[?OutputKey == `PrivateIp`].OutputValue' --output text)"

echo "${HOST_PUBLIC_IP}" > "${SCRIPT_DIR}/../${SHARED_DIR}/public_address"
echo "${HOST_PRIVATE_IP}" > "${SCRIPT_DIR}/../${SHARED_DIR}/private_address"

echo "Waiting up to 10 mins for RHEL host to be up."
timeout 10m aws ec2 wait instance-status-ok --instance-id "${INSTANCE_ID}" --no-cli-pager

# Add the host key to known_hosts to avoid prompts while maintaining security
echo "Adding host key for $HOST_PUBLIC_IP to known_hosts..."
max_attempts=5
retry_delay=5
for ((attempt=1; attempt<=max_attempts; attempt++)); do
    if ssh-keyscan -H "$HOST_PUBLIC_IP" >> ~/.ssh/known_hosts 2>/dev/null; then
        echo "Host key added successfully"
        break
    fi
    if ((attempt < max_attempts)); then
        echo "SSH not ready (attempt $attempt/$max_attempts), retrying in ${retry_delay}s..."
        sleep "$retry_delay"
    else
        echo "Warning: Could not retrieve host key after $max_attempts attempts"
    fi
done

echo "updating sshconfig for aws-hypervisor"
(cd "${SCRIPT_DIR}/.." && go run main.go -k aws-hypervisor -h "$HOST_PUBLIC_IP")

copy_configure_script
set_aws_machine_hostname

scp "$(cat "${SCRIPT_DIR}/../${SHARED_DIR}/ssh_user")@${HOST_PUBLIC_IP}:/tmp/init_output.txt" "${SCRIPT_DIR}/../${SHARED_DIR}/init_output.txt"

# Mark stack creation as successful (prevents capacity cleanup on exit)
touch "${SCRIPT_DIR}/../${SHARED_DIR}/.stack-created"

# Release capacity reservation now that instance is running
# The reservation served its purpose (guaranteeing capacity at creation time)
# Releasing it allows the instance to start/stop freely without reservation dependency
if [[ -n "${CAPACITY_RESERVATION_ID}" ]]; then
    msg_info "Releasing capacity reservation (no longer needed)..."

    # Remove the instance's association with the specific reservation
    # This changes the instance to use "open" preference (on-demand capacity)
    aws --region "${REGION}" ec2 modify-instance-capacity-reservation-attributes \
        --instance-id "${INSTANCE_ID}" \
        --capacity-reservation-specification "CapacityReservationPreference=open" \
        --no-cli-pager || msg_warning "Failed to modify instance capacity reservation attributes"

    # Cancel the capacity reservation
    cancel_capacity_reservation "${CAPACITY_RESERVATION_ID}" "${REGION}"

    # Clean up local files
    rm -f "${SCRIPT_DIR}/../${SHARED_DIR}/capacity-reservation-id"
    rm -f "${SCRIPT_DIR}/../${SHARED_DIR}/availability-zone"

    msg_info "Capacity reservation released successfully"
fi

msg_info "Instance creation completed successfully"
