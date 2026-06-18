#!/usr/bin/bash
set -euo pipefail

# Patches dev-scripts on a hypervisor to generate MAC-only fencing credentials
# instead of hostname-based ones, for verifying OCPEDGE-2692.
#
# Prerequisites:
#   - Hypervisor must be initialized (TNT `make init` or `make deploy`)
#     so that dev-scripts is already cloned on the hypervisor.
#   - A running cluster is NOT required — this patches source files
#     before the cluster is deployed.
#
# Usage: ./patch-devscripts-mac-fencing.sh [hypervisor_host]
#
# The hypervisor is auto-discovered from the TNT inventory file
# (deploy/openshift-clusters/inventory.ini). An explicit argument
# overrides auto-discovery.
#
# IMPORTANT: TNT's Ansible role runs `git checkout --force` on dev-scripts
# before every deployment, wiping these patches. Either:
#   a) Run this script AFTER TNT's git checkout (before make agent), or
#   b) Deploy directly on the hypervisor with `sudo make agent`
#
# After running this script, SSH to the hypervisor and run:
#   cd /home/ec2-user/openshift-metal3/dev-scripts
#   sudo rm -f /etc/NetworkManager/dnsmasq.d/openshift-ostest.conf
#   sudo setfacl -m u:qemu:rx /root
#   rm -rf ocp/ostest
#   sudo make agent

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
INVENTORY="${SCRIPT_DIR}/../deploy/openshift-clusters/inventory.ini"

if [[ -n "${1:-}" ]]; then
    HYPERVISOR="$1"
elif [[ -f "${INVENTORY}" ]]; then
    HYPERVISOR=$(awk '/^\[metal_machine\]/{found=1; next} found && /^[[:space:]]*$/{next} found && /^#/{next} found && /^\[/{exit} found{print $1; exit}' "${INVENTORY}")
    if [[ -z "${HYPERVISOR}" ]]; then
        echo "ERROR: Could not parse hypervisor from ${INVENTORY}"
        exit 1
    fi
    echo "Auto-discovered hypervisor from inventory: ${HYPERVISOR}"
else
    echo "ERROR: No hypervisor specified and inventory not found at ${INVENTORY}"
    echo "Usage: $0 [hypervisor_host]"
    exit 1
fi

DEV_SCRIPTS="/home/ec2-user/openshift-metal3/dev-scripts"
SSH_OPTS=(-o StrictHostKeyChecking=accept-new -o ServerAliveInterval=30 -o ServerAliveCountMax=120)

echo "==> Patching dev-scripts on ${HYPERVISOR} for MAC-only fencing credentials"

# Pre-flight: verify dev-scripts is cloned on the hypervisor
if ! ssh "${SSH_OPTS[@]}" "${HYPERVISOR}" test -d "${DEV_SCRIPTS}/agent"; then
    echo "ERROR: dev-scripts not found at ${DEV_SCRIPTS} on ${HYPERVISOR}"
    echo "Run 'make init' or 'make deploy' from deploy/ first."
    exit 1
fi

# Patch 0: Ensure AGENT_E2E_TEST_SCENARIO is set in the config file
echo "--- Patch 0/3: config file (AGENT_E2E_TEST_SCENARIO)"
# shellcheck disable=SC2087
ssh "${SSH_OPTS[@]}" "${HYPERVISOR}" bash -s "${DEV_SCRIPTS}" <<'PATCH0_EOF'
DEV_SCRIPTS="$1"
CONFIG=$(ls "${DEV_SCRIPTS}"/config_*.sh 2>/dev/null | head -1)
if [[ -z "$CONFIG" ]]; then
    echo "  SKIP: No config_*.sh found yet — will be created by 'make deploy'"
    exit 0
fi
echo "  Config file: $(basename "$CONFIG")"

if grep -q '^export AGENT_E2E_TEST_SCENARIO=' "$CONFIG"; then
    echo "  AGENT_E2E_TEST_SCENARIO already set"
elif grep -q '#.*export AGENT_E2E_TEST_SCENARIO=' "$CONFIG"; then
    sed -i 's/^#\s*export AGENT_E2E_TEST_SCENARIO=/export AGENT_E2E_TEST_SCENARIO=/' "$CONFIG"
    echo "  Uncommented AGENT_E2E_TEST_SCENARIO"
else
    echo 'export AGENT_E2E_TEST_SCENARIO="TNF_IPV4"' >> "$CONFIG"
    echo "  Added AGENT_E2E_TEST_SCENARIO=TNF_IPV4"
fi

# Fix OPENSHIFT_CI case sensitivity (dev-scripts checks [ TRUE == true ] which fails)
if grep -q 'OPENSHIFT_CI="TRUE"' "$CONFIG"; then
    sed -i 's/OPENSHIFT_CI="TRUE"/OPENSHIFT_CI="true"/' "$CONFIG"
    echo "  Fixed OPENSHIFT_CI case: TRUE → true"
else
    echo "  OPENSHIFT_CI case OK"
fi
PATCH0_EOF

# Patch 1: agent/05_agent_configure.sh
# - Collect master MACs into AGENT_MASTER_MACS[] array (after node_mac is read)
# - Export AGENT_MASTER_MACS_STR (after AGENT_MASTER_HOSTNAMES_STR)
echo "--- Patch 1/3: agent/05_agent_configure.sh"
# shellcheck disable=SC2087
ssh "${SSH_OPTS[@]}" "${HYPERVISOR}" bash -s "${DEV_SCRIPTS}" <<'PATCH1_EOF'
DEV_SCRIPTS="$1"
FILE="${DEV_SCRIPTS}/agent/05_agent_configure.sh"

# 1a: Add AGENT_MASTER_MACS collection after AGENT_NODES_MACS line
if grep -q 'AGENT_MASTER_MACS' "$FILE"; then
    echo "  Already patched (AGENT_MASTER_MACS found), skipping 1a"
else
    if ! grep -q 'AGENT_NODES_MACS+=("$node_mac")$' "$FILE"; then
        echo "  ERROR: Anchor pattern 'AGENT_NODES_MACS+=(\"\\$node_mac\")' not found in $FILE"
        echo "  Upstream dev-scripts may have changed. Patch 1a cannot be applied."
        exit 1
    fi
    sed -i '/AGENT_NODES_MACS+=("$node_mac")$/a\    if [[ "$node_type" == "master" ]]; then\n      AGENT_MASTER_MACS+=("$node_mac")\n    fi' "$FILE"
    if ! grep -q 'AGENT_MASTER_MACS' "$FILE"; then
        echo "  ERROR: Patch 1a failed — AGENT_MASTER_MACS not found after sed"
        exit 1
    fi
    echo "  Applied: AGENT_MASTER_MACS collection"
fi

# 1b: Export AGENT_MASTER_MACS_STR after AGENT_MASTER_HOSTNAMES_STR
if grep -q 'AGENT_MASTER_MACS_STR' "$FILE"; then
    echo "  Already patched (AGENT_MASTER_MACS_STR found), skipping 1b"
else
    if ! grep -q 'export AGENT_MASTER_HOSTNAMES_STR=' "$FILE"; then
        echo "  ERROR: Anchor pattern 'export AGENT_MASTER_HOSTNAMES_STR=' not found in $FILE"
        echo "  Upstream dev-scripts may have changed. Patch 1b cannot be applied."
        exit 1
    fi
    sed -i '/export AGENT_MASTER_HOSTNAMES_STR=/a\  master_macs=$(printf '"'"'%s,'"'"' "${AGENT_MASTER_MACS[@]}")\n  export AGENT_MASTER_MACS_STR=${master_macs::-1}' "$FILE"
    if ! grep -q 'AGENT_MASTER_MACS_STR' "$FILE"; then
        echo "  ERROR: Patch 1b failed — AGENT_MASTER_MACS_STR not found after sed"
        exit 1
    fi
    echo "  Applied: AGENT_MASTER_MACS_STR export"
fi
PATCH1_EOF

# Patch 2: agent/roles/manifests/vars/main.yml
# - Add agent_master_macs variable
echo "--- Patch 2/3: agent/roles/manifests/vars/main.yml"
# shellcheck disable=SC2087
ssh "${SSH_OPTS[@]}" "${HYPERVISOR}" bash -s "${DEV_SCRIPTS}" <<'PATCH2_EOF'
DEV_SCRIPTS="$1"
FILE="${DEV_SCRIPTS}/agent/roles/manifests/vars/main.yml"

if grep -q 'agent_master_macs' "$FILE"; then
    echo "  Already patched (agent_master_macs found), skipping"
else
    if ! grep -q '^agent_master_hostnames:' "$FILE"; then
        echo "  ERROR: Anchor pattern 'agent_master_hostnames:' not found in $FILE"
        echo "  Upstream dev-scripts may have changed. Patch 2 cannot be applied."
        exit 1
    fi
    sed -i '/^agent_master_hostnames:/a agent_master_macs: "{{ lookup('"'"'env'"'"', '"'"'AGENT_MASTER_MACS_STR'"'"') }}"' "$FILE"
    if ! grep -q 'agent_master_macs' "$FILE"; then
        echo "  ERROR: Patch 2 failed — agent_master_macs not found after sed"
        exit 1
    fi
    echo "  Applied: agent_master_macs variable"
fi
PATCH2_EOF

# Patch 3: agent/roles/manifests/templates/install-config_baremetal_yaml.j2
# - Replace hostname-based fencing with macaddress-based
echo "--- Patch 3/3: install-config_baremetal_yaml.j2 (MAC-only fencing)"
# shellcheck disable=SC2087
ssh "${SSH_OPTS[@]}" "${HYPERVISOR}" bash -s "${DEV_SCRIPTS}" <<'PATCH3_EOF'
DEV_SCRIPTS="$1"
FILE="${DEV_SCRIPTS}/agent/roles/manifests/templates/install-config_baremetal_yaml.j2"

if grep -q 'macaddress:' "$FILE"; then
    echo "  Already patched (macaddress found), skipping"
else
    MISSING_ANCHORS=()
    grep -q '{% set master_hostnames = agent_master_hostnames.split' "$FILE" || MISSING_ANCHORS+=("master_hostnames set")
    grep -q '{% for hostname in master_hostnames %}' "$FILE" || MISSING_ANCHORS+=("for hostname loop")
    grep -q 'hostname: {{hostname}}' "$FILE" || MISSING_ANCHORS+=("hostname field")
    if [[ ${#MISSING_ANCHORS[@]} -gt 0 ]]; then
        echo "  ERROR: Anchor patterns not found in $FILE: ${MISSING_ANCHORS[*]}"
        echo "  Upstream dev-scripts may have changed. Patch 3 cannot be applied."
        exit 1
    fi
    sed -i 's/{% set master_hostnames = agent_master_hostnames.split/{% set master_macs = agent_master_macs.split/' "$FILE"
    sed -i 's/{% for hostname in master_hostnames %}/{% for mac in master_macs %}/' "$FILE"
    sed -i 's/    - hostname: {{hostname}}/    - macaddress: {{ mac }}/' "$FILE"
    if ! grep -q 'macaddress:' "$FILE"; then
        echo "  ERROR: Patch 3 failed — macaddress not found after sed"
        exit 1
    fi
    echo "  Applied: macaddress-based fencing credentials"
fi
PATCH3_EOF

echo ""
echo "==> All patches applied successfully."
echo ""
echo "Next steps:"
echo "  1. SSH to the hypervisor:  ssh ${HYPERVISOR}"
echo "  2. cd ${DEV_SCRIPTS}"
echo "  3. make clean   (if cluster exists)"
echo "  4. sudo make agent   (deploy with MAC-only fencing)"
