#!/bin/bash
SCRIPT_DIR=$(dirname "$0")
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/common.sh"

instance_ip="$(cat "${SCRIPT_DIR}/../${SHARED_DIR}/ssh_user")@$(cat "${SCRIPT_DIR}/../${SHARED_DIR}/public_address")"
instance_host="$(cat "${SCRIPT_DIR}/../${SHARED_DIR}/public_address")"

# Add the host key to known_hosts to avoid prompts while maintaining security
echo "Adding host key for $instance_host to known_hosts..."
ssh-keyscan -H "$instance_host" >> ~/.ssh/known_hosts 2>/dev/null

ssh "$instance_ip 'mkdir -p ~/.ssh'"
scp "$SSH_PUBLIC_KEY" "$instance_ip:~/.ssh/id_rsa.pub"

# Generate SSH key pair on hypervisor for cluster VM access
echo "Generating SSH key pair on hypervisor for VM access..."
ssh "$instance_ip" '
  if [ ! -f ~/.ssh/id_rsa ]; then 
    ssh-keygen -t rsa -b 2048 -f ~/.ssh/id_rsa -N "" -C "hypervisor-vm-access"
    echo "Generated new SSH key pair for VM access"
  else
    echo "SSH key pair already exists"
  fi
  chmod 0600 ~/.ssh/id_rsa
  chmod 0644 ~/.ssh/id_rsa.pub
'

scp "${SCRIPT_DIR}/configure.sh" "$instance_ip:~/configure.sh"

# Create a minimal environment file with only the variables needed on the remote machine
cat > /tmp/profile.env.remote << EOF
export STACK_NAME="${STACK_NAME}"
export RHSM_ACTIVATION_KEY="${RHSM_ACTIVATION_KEY}"
export RHSM_ORG="${RHSM_ORG}"
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
