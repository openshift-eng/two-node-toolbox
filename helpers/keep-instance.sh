#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INSTANCE_DATA="${SCRIPT_DIR}/../deploy/aws-hypervisor/instance-data/node-0"
if [[ ! -f "${INSTANCE_DATA}/aws-instance-id" ]]; then
    echo "Error: No instance found. Please run 'make deploy' first." >&2
    exit 1
fi
INSTANCE_ID=$(cat "${INSTANCE_DATA}/aws-instance-id")
if [[ -z "${INSTANCE_ID}" ]]; then
    echo "Error: No instance found. Please run 'make deploy' first." >&2
    exit 1
fi

# common.sh syncs config/ files and sources instance.env (for REGION)
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/../deploy/common.sh"

REGION="${REGION:-${AWS_DEFAULT_REGION:-}}"
if [[ -z "${REGION}" ]]; then
    echo "ERROR: No AWS region configured. Set REGION in instance.env or export AWS_DEFAULT_REGION." >&2
    exit 1
fi

DAYS="${1:-2}"

if ! [[ "${DAYS}" =~ ^[1-9][0-9]*$ ]]; then
    echo "ERROR: Days must be a positive integer, got '${DAYS}'." >&2
    exit 1
fi

if (( DAYS > 5 )); then
    echo "ERROR: Days cannot exceed 5, got '${DAYS}'." >&2
    exit 1
fi

TAG_VALUE="keep-${DAYS}"

echo "Tagging instance ${INSTANCE_ID} in ${REGION} with ${TAG_VALUE}"
aws ec2 create-tags --region "${REGION}" --resources "${INSTANCE_ID}" \
    --tags "Key=${TAG_VALUE},Value=true" --no-cli-pager
echo "Done."
