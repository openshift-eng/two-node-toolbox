#!/usr/bin/env bash
SCRIPT_DIR=$(dirname "$0")
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/../../common.sh"

node_dir="$(get_node_dir)"
instance_ip="$(cat "${node_dir}/ssh_user")@$(cat "${node_dir}/public_address")"

# Use the private key corresponding to the configured public key
if [[ -n "${SSH_PUBLIC_KEY}" ]]; then
    # Convert public key path to private key path
    SSH_PRIVATE_KEY="${SSH_PUBLIC_KEY%.pub}"
    ssh -i "${SSH_PRIVATE_KEY}" "$instance_ip"
else
    ssh "$instance_ip"
fi
