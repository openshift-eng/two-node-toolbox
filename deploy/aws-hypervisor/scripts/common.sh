#!/bin/bash
SCRIPT_DIR=$(dirname "$0")
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/../instance.env"

# Set defaults
export STACK_NAME="${STACK_NAME:-${USER}-dev}"
export SHARED_DIR="${SHARED_DIR:-instance-data}"
export RHEL_HOST_ARCHITECTURE="${RHEL_HOST_ARCHITECTURE:-x86_64}"
export EC2_INSTANCE_TYPE="${EC2_INSTANCE_TYPE:-c5n.metal}"
export RHEL_VERSION="${RHEL_VERSION:-9.6}"

# Spot instance defaults
export USE_SPOT_INSTANCE="${USE_SPOT_INSTANCE:-false}"
# Availability zone override (optional)
export AVAILABILITY_ZONE="${AVAILABILITY_ZONE:-}"

# Capacity reservation defaults (ignored when USE_SPOT_INSTANCE=true)
export ENABLE_CAPACITY_RESERVATION="${ENABLE_CAPACITY_RESERVATION:-true}"
export CAPACITY_RESERVATION_DURATION_MINUTES="${CAPACITY_RESERVATION_DURATION_MINUTES:-60}"

readonly COLOR_RED='\033[0;31m'
readonly COLOR_YELLOW='\033[0;33m'
readonly COLOR_BLUE='\033[0;34m'
readonly COLOR_CLEAR='\033[0m'

function msg_err() {
  echo -e "${COLOR_RED}ERROR: ${1}${COLOR_CLEAR}" >&2
}

function msg_warning() {
  echo -e "${COLOR_YELLOW}WARNING: ${1}${COLOR_CLEAR}" >&2
}

function msg_info() {
  echo -e "${COLOR_BLUE}INFO: ${1}${COLOR_CLEAR}" >&2
}

function aws_ec2_describe_images() {
  # shellcheck disable=SC2153 # REGION is an env var from instance.env, not a misspelling of local 'region'
  aws ec2 describe-images \
  --query 'reverse(sort_by(Images, &CreationDate))[].[Name, ImageId, CreationDate]' \
  --filters "Name=name,Values=RHEL-${RHEL_VERSION}.*GA*${RHEL_HOST_ARCHITECTURE}*" \
  --region "${REGION}" \
  --owners amazon \
  --output json \
  --no-cli-pager
}

function get_rhel_ami() {
  local rhel_host_ami_object
  local ec2_instances
  if ! ec2_instances="$(aws_ec2_describe_images)";
  then
    msg_err " getting AMI from aws cli: $ec2_instances" >&2
    echo ""
  fi

  if rhel_host_ami_object=$( echo "$ec2_instances" | jq -re 'map({ name: .[0], id: .[1], creationDate: .[2]}) | .[0]');
  then
        ami_name="$(echo "$rhel_host_ami_object" | jq '.name')"
        ami_id="$(echo "$rhel_host_ami_object" | jq '.id')"
        msg_info "Found AMI: $ami_name" >&2
        msg_info "Found AMI ID: $ami_id" >&2
        echo "${ami_id}"
  else
        msg_err "error getting AMI's $rhel_host_ami_object" >&2
        echo ""
  fi
}

function copy_configure_script() {
    local instance_ip
    instance_ip="$(cat "${SCRIPT_DIR}/../${SHARED_DIR}/ssh_user")@$(cat "${SCRIPT_DIR}/../${SHARED_DIR}/public_address")"
    msg_info "copying over config ${SCRIPT_DIR}/configure.sh and making it executable"
    scp "${SCRIPT_DIR}/configure.sh" "$instance_ip:~/configure.sh"
    ssh "$instance_ip" 'chmod +x ~/configure.sh'
}

# shellcheck disable=SC2029 # we want interpolation for the stack name in the ssh command
function set_aws_machine_hostname() {
    local instance_ip
    instance_ip="$(cat "${SCRIPT_DIR}/../${SHARED_DIR}/ssh_user")@$(cat "${SCRIPT_DIR}/../${SHARED_DIR}/public_address")"
    msg_info "setting machine hostname to aws-${STACK_NAME}"
    ssh "$instance_ip" "sudo hostnamectl set-hostname aws-$STACK_NAME"
}

# Creates a time-limited capacity reservation and returns the reservation ID and availability zone.
# Auto-detects the first available AZ in the configured region.
# The reservation expires after CAPACITY_RESERVATION_DURATION_MINUTES (default: 60 minutes).
# Exits with error if capacity is unavailable.
# Usage: result=$(create_capacity_reservation "instance_type" "region")
#        reservation_id=$(echo "$result" | awk '{print $1}')
#        availability_zone=$(echo "$result" | awk '{print $2}')
function create_capacity_reservation() {
    local instance_type="$1"
    local region="$2"
    local instance_platform="${3:-Red Hat Enterprise Linux}"
    local duration_minutes="${CAPACITY_RESERVATION_DURATION_MINUTES:-60}"

    # Calculate end date (current time + duration)
    local end_date
    end_date=$(date -u -d "+${duration_minutes} minutes" '+%Y-%m-%dT%H:%M:%SZ')

    msg_info "Checking EC2 capacity availability for ${instance_type} (${instance_platform}) in ${region}..."
    msg_info "Reservation will expire at ${end_date} (${duration_minutes} minutes from now)"

    # Auto-detect available AZs in region
    local az_list
    if ! az_list=$(aws ec2 describe-availability-zones \
        --region "${region}" \
        --filters "Name=state,Values=available" \
        --query 'AvailabilityZones[*].ZoneName' \
        --output text \
        --no-cli-pager); then
        msg_err "Failed to query availability zones in region ${region}"
        return 1
    fi

    if [[ -z "${az_list}" ]]; then
        msg_err "No available availability zones found in region ${region}"
        return 1
    fi

    # Try each AZ until we find one with capacity
    local reservation_output
    local create_status
    local reservation_id
    local availability_zone

    for az in ${az_list}; do
        msg_info "Trying availability zone: ${az}..."

        set +e
        reservation_output=$(aws ec2 create-capacity-reservation \
            --region "${region}" \
            --instance-type "${instance_type}" \
            --instance-platform "${instance_platform}" \
            --instance-count 1 \
            --availability-zone "${az}" \
            --instance-match-criteria "targeted" \
            --end-date-type "limited" \
            --end-date "${end_date}" \
            --output json \
            --no-cli-pager 2>&1)
        create_status=$?
        set -e

        if [[ ${create_status} -eq 0 ]]; then
            # Extract reservation ID
            reservation_id=$(echo "${reservation_output}" | jq -r '.CapacityReservation.CapacityReservationId')

            if [[ -n "${reservation_id}" && "${reservation_id}" != "null" ]]; then
                availability_zone="${az}"
                msg_info "Capacity reservation created: ${reservation_id} in ${availability_zone}"
                echo "${reservation_id} ${availability_zone}"
                return 0
            fi
        fi

        # Check if it's a capacity error (expected) vs other error (unexpected)
        if echo "${reservation_output}" | grep -qi "InsufficientInstanceCapacity\|Unsupported"; then
            msg_info "No capacity in ${az}, trying next..."
        else
            msg_warning "Unexpected error in ${az}: ${reservation_output}"
        fi
    done

    # No capacity found in any AZ
    msg_err "Failed to reserve capacity for ${instance_type} in any availability zone in ${region}"
    msg_err ""
    msg_err "Possible solutions:"
    msg_err "  1. Try a different region (set REGION in instance.env)"
    msg_err "  2. Try a different instance type (set EC2_INSTANCE_TYPE in instance.env)"
    msg_err "  3. Wait and retry (capacity constraints are often temporary)"
    return 1
}

# Cancels a capacity reservation by ID. Handles already-cancelled reservations gracefully.
# Usage: cancel_capacity_reservation "reservation_id" "region"
function cancel_capacity_reservation() {
    local reservation_id="$1"
    local region="$2"

    if [[ -z "${reservation_id}" || "${reservation_id}" == "null" ]]; then
        return 0  # Nothing to cancel
    fi

    msg_info "Canceling capacity reservation ${reservation_id}..."

    set +e
    aws ec2 cancel-capacity-reservation \
        --region "${region}" \
        --capacity-reservation-id "${reservation_id}" \
        --no-cli-pager >/dev/null 2>&1
    local cancel_status=$?
    set -e

    if [[ ${cancel_status} -eq 0 ]]; then
        msg_info "Capacity reservation canceled successfully"
    else
        msg_warning "Failed to cancel capacity reservation (may already be canceled)"
    fi
}
