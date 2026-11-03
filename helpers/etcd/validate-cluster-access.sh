#!/usr/bin/env bash
# Validate access to cluster VMs via Ansible and OpenShift cluster via oc
# This is the comprehensive validation script for etcd troubleshooting

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
INVENTORY_PATH="${INVENTORY_PATH:-deploy/openshift-clusters/inventory.ini}"
PROXY_ENV_PATH="${PROXY_ENV_PATH:-deploy/openshift-clusters/proxy.env}"

# Color codes
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

info() {
    echo -e "${GREEN}✓${NC} $*"
}

warn() {
    echo -e "${YELLOW}⚠${NC} $*"
}

error() {
    echo -e "${RED}✗${NC} $*"
}

section() {
    echo -e "\n${BLUE}===${NC} $* ${BLUE}===${NC}"
}

cd "${REPO_ROOT}"

EXIT_CODE=0

section "Validating Ansible Access to Cluster VMs"

# Check if inventory exists
if [ ! -f "${INVENTORY_PATH}" ]; then
    error "Inventory file not found: ${INVENTORY_PATH}"
    EXIT_CODE=1
else
    info "Inventory file found: ${INVENTORY_PATH}"

    # Run Ansible validation playbook
    if ansible-playbook "${SCRIPT_DIR}/playbooks/validate-access.yml" \
        -i "${INVENTORY_PATH}" > /tmp/ansible-validation.log 2>&1; then
        info "Ansible connectivity test passed"
        echo "  See /tmp/ansible-validation.log for details"
    else
        error "Ansible connectivity test failed"
        echo "  See /tmp/ansible-validation.log for details"
        EXIT_CODE=1
    fi
fi

section "Validating OpenShift Cluster Access"

# Check if oc is available
if ! command -v oc &> /dev/null; then
    warn "oc command not found in PATH"
    warn "Cluster API access will not be available (this is OK if etcd is down)"
else
    info "oc command found"

    # Try direct access
    if oc version --request-timeout=5s &>/dev/null; then
        info "Direct cluster access successful"
        PROXY_REQUIRED=false
        CLUSTER_ACCESS=true
    else
        warn "Direct cluster access failed"

        # Check for proxy.env
        if [ -f "${PROXY_ENV_PATH}" ]; then
            info "Found proxy configuration: ${PROXY_ENV_PATH}"

            # Source and test proxy access
            # shellcheck disable=SC1090
            source "${PROXY_ENV_PATH}"

            if oc version --request-timeout=5s &>/dev/null; then
                info "Cluster access via proxy successful"
                PROXY_REQUIRED=true
                CLUSTER_ACCESS=true
            else
                warn "Cluster access failed even with proxy"
                warn "This is expected if etcd is down - will rely on direct VM access"
                CLUSTER_ACCESS=false
            fi
        else
            warn "No proxy.env found at: ${PROXY_ENV_PATH}"
            warn "Cluster access unavailable - this is OK if etcd is down"
            CLUSTER_ACCESS=false
        fi
    fi

    # If we have cluster access, test basic operations
    if [ "${CLUSTER_ACCESS:-false}" = "true" ]; then
        section "Testing OpenShift Cluster Operations"

        if oc get nodes &>/dev/null; then
            info "Successfully queried cluster nodes"
            oc get nodes -o wide | sed 's/^/  /'
        else
            warn "Failed to query cluster nodes (may be expected if etcd is down)"
        fi

        if oc get co etcd &>/dev/null; then
            info "Successfully queried etcd cluster operator"
            oc get co etcd | sed 's/^/  /'
        else
            warn "Failed to query etcd cluster operator (may be expected if etcd is down)"
        fi
    fi
fi

section "Validation Summary"

if [ ${EXIT_CODE} -eq 0 ]; then
    info "All validation checks passed"
    if [ "${PROXY_REQUIRED:-false}" = "true" ]; then
        warn "NOTE: Cluster access requires proxy.env to be sourced"
        echo "  Use the oc-wrapper.sh script or source ${PROXY_ENV_PATH} before oc commands"
    fi
else
    error "Some validation checks failed"
    echo "Please resolve the issues above before proceeding with troubleshooting"
fi

exit ${EXIT_CODE}
