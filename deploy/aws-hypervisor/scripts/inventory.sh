#!/bin/bash

SCRIPT_DIR=$(dirname "$0")
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/common.sh"

set -o nounset
set -o errexit
set -o pipefail

# Paths - use deployment-specific directory
INVENTORY_BASE_DIR="${SCRIPT_DIR}/../../openshift-clusters"
INVENTORY_DIR="${INVENTORY_BASE_DIR}/deployments/${DEPLOYMENT_ID}"
INVENTORY_FILE="${INVENTORY_DIR}/inventory.ini"
INVENTORY_TEMPLATE="${INVENTORY_BASE_DIR}/inventory.ini.sample"

# Create deployment-specific directory if it doesn't exist
mkdir -p "${INVENTORY_DIR}"

# Check if instance data exists
if [[ ! -f "${SCRIPT_DIR}/../${SHARED_DIR}/public_address" ]]; then
    echo "Error: No public address found. Please run 'make deploy' first."
    exit 1
fi

if [[ ! -f "${SCRIPT_DIR}/../${SHARED_DIR}/ssh_user" ]]; then
    echo "Error: No ssh user found. Please run 'make deploy' first."
    exit 1
fi

# Read instance data
PUBLIC_IP="$(< "${SCRIPT_DIR}/../${SHARED_DIR}/public_address" tr -d '\n')"
SSH_USER="$(< "${SCRIPT_DIR}/../${SHARED_DIR}/ssh_user" tr -d '\n')"

echo "Updating inventory for deployment '${DEPLOYMENT_ID}' with:"
echo "  User: ${SSH_USER}"
echo "  IP:   ${PUBLIC_IP}"
echo "  Inventory: ${INVENTORY_FILE}"

# Function to update inventory file using Python ConfigParser
function update_config() {
    local inventory_file="$1"
    HOST_ENTRY="${SSH_USER}@${PUBLIC_IP} ansible_ssh_extra_args=\"-o ServerAliveInterval=30 -o ServerAliveCountMax=120\""

    python3 -c "
import configparser

# ConfigParser with colon as delimiter to avoid conflicts with = in host entries
# This allows host entries with = in them to work with Python 3.14's stricter validation
config = configparser.ConfigParser(allow_no_value=True, delimiters=(':',))
config.optionxform = str  # Preserve case sensitivity
config.read('$inventory_file')

# Ensure the metal_machine section exists
if not config.has_section('metal_machine'):
    config.add_section('metal_machine')

# Remove any existing host entries (lines with @ symbol)
items_to_remove = []
if config.has_section('metal_machine'):
    for item in config.options('metal_machine'):
        if '@' in item:
            items_to_remove.append(item)

for item in items_to_remove:
    config.remove_option('metal_machine', item)

# Add the new host entry (without a value, as it's just a host declaration)
config.set('metal_machine', '$HOST_ENTRY', None)

# Write the updated config
with open('$inventory_file', 'w') as configfile:
    config.write(configfile, space_around_delimiters=False)
"
}

# Check if inventory file exists
if [[ -f "${INVENTORY_FILE}" ]]; then
    echo "Updating existing inventory file..."
    
    # Create a backup in the inventory-backup directory
    BACKUP_DIR="${INVENTORY_DIR}/inventory-backup"
    mkdir -p "${BACKUP_DIR}"
    cp "${INVENTORY_FILE}" "${BACKUP_DIR}/inventory.ini.backup.$(date +%s)"
    
    update_config "${INVENTORY_FILE}"
    echo "Updated existing inventory file: ${INVENTORY_FILE}"
else
    echo "Creating new inventory file from template..."
    
    # Check if template exists
    if [[ ! -f "${INVENTORY_TEMPLATE}" ]]; then
        echo "Error: Template file not found: ${INVENTORY_TEMPLATE}"
        exit 1
    fi
    
    # Copy template and update with actual values
    cp "${INVENTORY_TEMPLATE}" "${INVENTORY_FILE}"
    update_config "${INVENTORY_FILE}"
    echo "Created new inventory file: ${INVENTORY_FILE}"
fi

echo "Inventory file updated successfully!"
echo ""
echo "Current inventory content:"
cat "${INVENTORY_FILE}" 