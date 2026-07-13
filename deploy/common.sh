#!/bin/bash
SCRIPT_DIR=$(dirname "$0")
COMMON_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${COMMON_DIR}/.." && pwd)"

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

# Config sync manifest: "src:dest[:dest2]" entries, where src is relative to
# config/ at the repository root and destinations are relative to the
# repository root.
CONFIG_SYNC_MANIFEST=(
  "instance.env:deploy/aws-hypervisor/instance.env"
  "config_arbiter.sh:deploy/openshift-clusters/roles/dev-scripts/install-dev/files/config_arbiter.sh"
  "config_fencing.sh:deploy/openshift-clusters/roles/dev-scripts/install-dev/files/config_fencing.sh"
  "config_sno.sh:deploy/openshift-clusters/roles/dev-scripts/install-dev/files/config_sno.sh"
  "config_baremetal_fencing.sh:deploy/openshift-clusters/roles/dev-scripts/install-dev/files/config_baremetal_fencing.sh"
  "pull-secret.json:deploy/openshift-clusters/roles/dev-scripts/install-dev/files/pull-secret.json:deploy/openshift-clusters/roles/kcli/kcli-install/files/pull-secret.json"
  "kcli.yml:deploy/openshift-clusters/vars/kcli.yml"
  "assisted.yml:deploy/openshift-clusters/vars/assisted.yml"
  "init-host.yml.local:deploy/openshift-clusters/vars/init-host.yml.local"
)

# Copies files the user created in config/ to the canonical locations the
# scripts and playbooks read from. A file is only copied when the destination
# is missing or the config/ copy is newer, so direct edits to the canonical
# locations are never overwritten. Never deletes or writes back into config/.
function sync_config_files() {
  export CONFIG_SYNCED_COUNT=0
  export CONFIG_SYNC_ERRORS=0
  local entry src dest
  local -a fields
  for entry in "${CONFIG_SYNC_MANIFEST[@]}"; do
    IFS=':' read -r -a fields <<< "${entry}"
    src="${REPO_ROOT}/config/${fields[0]}"
    [[ -f "${src}" ]] || continue
    if [[ ! -s "${src}" ]]; then
      msg_warning "config/${fields[0]} is empty (0 bytes), skipping sync"
      continue
    fi
    for dest in "${fields[@]:1}"; do
      if [[ ! -f "${REPO_ROOT}/${dest}" || "${src}" -nt "${REPO_ROOT}/${dest}" ]]; then
        msg_info "config/${fields[0]} is newer, updating ${dest}"
        if ! cp "${src}" "${REPO_ROOT}/${dest}"; then
          msg_err "Failed to sync config/${fields[0]} to ${dest}"
          CONFIG_SYNC_ERRORS=$((CONFIG_SYNC_ERRORS + 1))
          continue
        fi
        CONFIG_SYNCED_COUNT=$((CONFIG_SYNCED_COUNT + 1))
      fi
    done
  done
}

# Set USER if not already set (needed by instance.env)
export USER="${USER:-$(whoami 2>/dev/null || echo 'user')}"

if [[ -f "${COMMON_DIR}/aws-hypervisor/instance.env" ]]; then
  # shellcheck source=/dev/null
  source "${COMMON_DIR}/aws-hypervisor/instance.env"
elif [[ "${SKIP_INSTANCE_ENV_WARNING:-0}" != "1" ]]; then
  msg_warning "instance.env not found (only needed for AWS hypervisor targets). To create it: cp config/instance.env.template config/instance.env and edit it."
fi

# Set defaults
export STACK_NAME="${STACK_NAME:-${USER}-dev}"
export SHARED_DIR="${SHARED_DIR:-instance-data}"
export RHEL_HOST_ARCHITECTURE="${RHEL_HOST_ARCHITECTURE:-x86_64}"
export EC2_INSTANCE_TYPE="${EC2_INSTANCE_TYPE:-c5n.metal}"
export RHEL_VERSION="${RHEL_VERSION:-9.6}"

# Capacity reservation defaults
export ENABLE_CAPACITY_RESERVATION="${ENABLE_CAPACITY_RESERVATION:-true}"
export CAPACITY_RESERVATION_DURATION_MINUTES="${CAPACITY_RESERVATION_DURATION_MINUTES:-60}"

export NODE_ID="${NODE_ID:-node-0}"

get_shared_dir() {
  echo "${COMMON_DIR}/aws-hypervisor/${SHARED_DIR}"
}

get_node_dir() {
  local node_dir="${COMMON_DIR}/aws-hypervisor/${SHARED_DIR}/${NODE_ID}"
  if [[ ! -d "$node_dir" && -f "${COMMON_DIR}/aws-hypervisor/${SHARED_DIR}/aws-instance-id" ]]; then
    echo "${COMMON_DIR}/aws-hypervisor/${SHARED_DIR}"
    return
  fi
  echo "$node_dir"
}

function print_proxy_instructions() {
    echo ""
    echo "Next steps:"
    echo "1. Source the proxy environment from anywhere:"
    echo "   source ${DEPLOY_DIR}/openshift-clusters/proxy.env"
    echo "   (or from openshift-clusters directory: source proxy.env)"
    echo "2. Verify cluster access: oc get nodes"
    echo "3. Access the cluster console if needed"
}

function get_ami_arch() {
  local arch="${RHEL_HOST_ARCHITECTURE}"
  if [[ "${arch}" == "aarch64" ]]; then
    arch="arm64"
  fi
  echo "${arch}"
}

function aws_ec2_describe_images() {
  local ami_arch
  ami_arch="$(get_ami_arch)"
  # shellcheck disable=SC2153 # REGION is an env var from instance.env, not a misspelling of local 'region'
  aws ec2 describe-images \
  --query 'reverse(sort_by(Images, &CreationDate))[].[Name, ImageId, CreationDate]' \
  --filters "Name=name,Values=RHEL-${RHEL_VERSION}*${ami_arch}*" \
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
    local node_dir
    node_dir="$(get_node_dir)"
    local instance_ip
    instance_ip="$(cat "${node_dir}/ssh_user")@$(cat "${node_dir}/public_address")"
    msg_info "copying over config ${SCRIPT_DIR}/configure.sh and making it executable"
    scp "${SCRIPT_DIR}/configure.sh" "$instance_ip:~/configure.sh"
    ssh "$instance_ip" 'chmod +x ~/configure.sh'
}

# shellcheck disable=SC2029 # we want interpolation for the stack name in the ssh command
function set_aws_machine_hostname() {
    local node_dir
    node_dir="$(get_node_dir)"
    local instance_ip
    instance_ip="$(cat "${node_dir}/ssh_user")@$(cat "${node_dir}/public_address")"
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
