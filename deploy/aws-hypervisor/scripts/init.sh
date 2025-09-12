#!/bin/bash
SCRIPT_DIR=$(dirname "$0")
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/common.sh"

instance_ip="$(cat "${SCRIPT_DIR}/../${SHARED_DIR}/ssh_user")@$(cat "${SCRIPT_DIR}/../${SHARED_DIR}/public_address")"
instance_host="$(cat "${SCRIPT_DIR}/../${SHARED_DIR}/public_address")"

# Add the host key to known_hosts to avoid prompts while maintaining security
echo "Adding host key for $instance_host to known_hosts..."
ssh-keyscan -H "$instance_host" >> ~/.ssh/known_hosts 2>/dev/null

scp "${SCRIPT_DIR}/configure.sh" "$instance_ip:~/configure.sh"

# Create a minimal environment file with only the variables needed on the remote machine
cat > /tmp/profile.env.remote << EOF
export STACK_NAME="${STACK_NAME}"
export RHSM_ACTIVATION_KEY="${RHSM_ACTIVATION_KEY}"
export RHSM_ORG="${RHSM_ORG}"
export DEFAULT_OCP_VERSION="${DEFAULT_OCP_VERSION}"
EOF
scp /tmp/profile.env.remote "$instance_ip:profile.env"
rm /tmp/profile.env.remote

ssh "$instance_ip" 'sudo chmod +x ~/configure.sh'

# Only drop into interactive shell if RHSM_ACTIVATION_KEY is not set
if [[ -z "${RHSM_ACTIVATION_KEY:-}" ]]; then
    echo "RHSM_ACTIVATION_KEY not set, dropping into interactive shell for manual setup..."
    ssh "$instance_ip"
else
    echo "RHSM_ACTIVATION_KEY provided, running configure.sh automatically..."
    ssh "$instance_ip" './configure.sh'
fi
