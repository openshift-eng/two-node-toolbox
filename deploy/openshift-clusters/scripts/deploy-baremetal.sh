#!/usr/bin/env bash
#
# Deploy a TNF fencing cluster on adopted baremetal nodes.
#
# Thin wrapper that calls the deploy-baremetal.yml Ansible playbook
# targeting the [provisioning_host] group from inventory_baremetal.ini.
#
# Expects adoption artifacts from 'make baremetal-adopt'.
#
# Usage:
#   deploy-baremetal.sh [-- <extra ansible-playbook args>]

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
OC_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
DEPLOY_DIR="$(cd "${OC_DIR}/.." && pwd)"
# shellcheck source=/dev/null
source "${DEPLOY_DIR}/common.sh"

set -o nounset
set -o errexit
set -o pipefail

INVENTORY="${OC_DIR}/inventory_baremetal.ini"
PLAYBOOK="${OC_DIR}/deploy-baremetal.yml"

if [[ ! -f "${INVENTORY}" ]]; then
    echo "Error: inventory_baremetal.ini not found in ${OC_DIR}/"
    echo "Copy inventory_baremetal.ini.sample, fill in your node details,"
    echo "and configure the [provisioning_host] section."
    exit 1
fi

if ! grep -qE '^\[provisioning_host\]' "${INVENTORY}"; then
    echo "Error: [provisioning_host] section not found in ${INVENTORY}"
    echo "Add a [provisioning_host] section with the target host."
    exit 1
fi

if ! grep -qvE '^\s*(#|$|\[)' <(sed -n '/\[provisioning_host\]/,/^\[/p' "${INVENTORY}" | tail -n +2); then
    echo "Error: [provisioning_host] section has no hosts configured."
    echo "Uncomment and configure a host entry in ${INVENTORY}."
    echo "For local deployment, add: localhost ansible_connection=local"
    exit 1
fi

echo "Deploying baremetal TNF cluster via provisioning host..."

cd "${OC_DIR}"
ansible-playbook "${PLAYBOOK}" -i "${INVENTORY}" "$@"
