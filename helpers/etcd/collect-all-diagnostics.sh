#!/usr/bin/env bash
# Master orchestration script for collecting all etcd/Pacemaker diagnostics
# Collects both VM-level data (via Ansible) and cluster-level data (via oc)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
INVENTORY_PATH="${INVENTORY_PATH:-deploy/openshift-clusters/inventory.ini}"
PROXY_ENV_PATH="${PROXY_ENV_PATH:-deploy/openshift-clusters/proxy.env}"
TIMESTAMP=$(date +%Y%m%dT%H%M%S)
OUTPUT_DIR="/tmp/etcd-diagnostics-${TIMESTAMP}"

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

section "Etcd/Pacemaker Diagnostic Collection"
echo "Timestamp: ${TIMESTAMP}"
echo "Output Directory: ${OUTPUT_DIR}"

# Create output directory
mkdir -p "${OUTPUT_DIR}/openshift"

# ============================================================
# Phase 1: Validate Access
# ============================================================

section "Phase 1: Validating Access"

if ! "${SCRIPT_DIR}/validate-cluster-access.sh"; then
    error "Access validation failed. Please resolve issues before collecting diagnostics."
    exit 1
fi

# ============================================================
# Phase 2: Collect VM-Level Data
# ============================================================

section "Phase 2: Collecting VM-Level Diagnostics (Pacemaker/Etcd)"

if ! ansible-playbook "${SCRIPT_DIR}/playbooks/collect-diagnostics.yml" \
    -i "${INVENTORY_PATH}" \
    -e "output_dir=${OUTPUT_DIR}"; then
    error "VM-level data collection failed"
    exit 1
fi

info "VM-level diagnostics collected successfully"

# ============================================================
# Phase 3: Collect OpenShift Cluster Data
# ============================================================

section "Phase 3: Collecting OpenShift Cluster-Level Diagnostics"

# Determine if proxy is needed
PROXY_REQUIRED=false
if ! oc version --request-timeout=5s &>/dev/null; then
    if [ -f "${PROXY_ENV_PATH}" ]; then
        info "Sourcing proxy configuration for cluster access"
        # shellcheck disable=SC1090
        source "${PROXY_ENV_PATH}"
        PROXY_REQUIRED=true
    else
        warn "Cannot access cluster and no proxy.env found - skipping cluster-level collection"
        PROXY_REQUIRED=skip
    fi
fi

if [ "${PROXY_REQUIRED}" != "skip" ]; then
    # Collect node information
    info "Collecting node status"
    oc get nodes -o wide > "${OUTPUT_DIR}/openshift/nodes.txt" 2>&1 || warn "Failed to get nodes"
    oc get nodes -o yaml > "${OUTPUT_DIR}/openshift/nodes.yaml" 2>&1 || warn "Failed to get nodes yaml"

    # Collect etcd operator status
    info "Collecting etcd cluster operator status"
    oc get co etcd > "${OUTPUT_DIR}/openshift/etcd_operator.txt" 2>&1 || warn "Failed to get etcd operator"
    oc get co etcd -o yaml > "${OUTPUT_DIR}/openshift/etcd_operator.yaml" 2>&1 || warn "Failed to get etcd operator yaml"

    # Collect all cluster operators
    info "Collecting all cluster operators"
    oc get co > "${OUTPUT_DIR}/openshift/cluster_operators.txt" 2>&1 || warn "Failed to get cluster operators"
    oc get co -o yaml > "${OUTPUT_DIR}/openshift/cluster_operators.yaml" 2>&1 || warn "Failed to get cluster operators yaml"

    # Check for degraded operators
    info "Checking for degraded operators"
    oc get co --no-headers | grep -v "True.*False.*False" > "${OUTPUT_DIR}/openshift/degraded_operators.txt" 2>&1 || true

    # Collect etcd pods (should not exist in TNF, but check anyway)
    info "Checking for etcd pods in openshift-etcd namespace"
    oc get pods -n openshift-etcd > "${OUTPUT_DIR}/openshift/etcd_pods.txt" 2>&1 || warn "Failed to get etcd pods"
    oc get pods -n openshift-etcd -o yaml > "${OUTPUT_DIR}/openshift/etcd_pods.yaml" 2>&1 || true

    # Collect machine config pool status
    info "Collecting machine config pool status"
    oc get mcp master > "${OUTPUT_DIR}/openshift/mcp_master.txt" 2>&1 || warn "Failed to get MCP master"
    oc get mcp master -o yaml > "${OUTPUT_DIR}/openshift/mcp_master.yaml" 2>&1 || warn "Failed to get MCP master yaml"

    # Collect recent events
    info "Collecting recent etcd-related events"
    oc get events -n openshift-etcd --sort-by='.lastTimestamp' > "${OUTPUT_DIR}/openshift/etcd_events.txt" 2>&1 || warn "Failed to get etcd events"
    oc get events -A --sort-by='.lastTimestamp' | tail -100 > "${OUTPUT_DIR}/openshift/recent_events.txt" 2>&1 || warn "Failed to get recent events"

    info "OpenShift cluster-level diagnostics collected successfully"
else
    warn "Skipped OpenShift cluster-level data collection (no cluster access)"
fi

# ============================================================
# Phase 4: Create Summary Report
# ============================================================

section "Phase 4: Creating Summary Report"

cat > "${OUTPUT_DIR}/DIAGNOSTIC_REPORT.txt" <<EOF
Etcd/Pacemaker Diagnostic Collection Report
============================================

Collection Time: $(date -Iseconds)
Collection Duration: \$SECONDS seconds

Output Directory Structure:
${OUTPUT_DIR}/
├── DIAGNOSTIC_REPORT.txt          (this file)
├── README.txt                      (collection metadata)
├── <node-1>/                       (VM-level diagnostics for node 1)
│   ├── pcs_status.txt
│   ├── pcs_resource_status.txt
│   ├── cib_attributes.txt
│   ├── podman_ps.txt
│   ├── podman_inspect.json
│   ├── podman_logs.txt
│   ├── etcd_member_list.txt
│   ├── etcd_endpoint_health.txt
│   ├── etcd_endpoint_status.txt
│   ├── journal_pacemaker.log
│   ├── journal_corosync.log
│   └── journal_etcd.log
├── <node-2>/                       (VM-level diagnostics for node 2)
│   └── (same structure as node-1)
└── openshift/                      (cluster-level diagnostics)
    ├── nodes.txt
    ├── nodes.yaml
    ├── etcd_operator.txt
    ├── etcd_operator.yaml
    ├── cluster_operators.txt
    ├── degraded_operators.txt
    ├── etcd_pods.txt
    ├── mcp_master.txt
    └── etcd_events.txt

Access Configuration:
- Inventory: ${INVENTORY_PATH}
- Proxy Required: ${PROXY_REQUIRED}
EOF

if [ "${PROXY_REQUIRED}" = "true" ]; then
    echo "- Proxy Config: ${PROXY_ENV_PATH}" >> "${OUTPUT_DIR}/DIAGNOSTIC_REPORT.txt"
fi

cat >> "${OUTPUT_DIR}/DIAGNOSTIC_REPORT.txt" <<EOF

Quick Analysis Commands:
========================

# Compare cluster IDs between nodes
grep -r "cluster_id" ${OUTPUT_DIR}/*/cib_attributes.txt

# Check if etcd is running on both nodes
grep -r "etcd" ${OUTPUT_DIR}/*/podman_ps.txt

# Look for failed Pacemaker actions
grep -i "failed\|error" ${OUTPUT_DIR}/*/pcs_status.txt

# Check etcd member consistency
cat ${OUTPUT_DIR}/*/etcd_member_list.txt

# Review recent errors in logs
grep -i "error\|fatal\|panic" ${OUTPUT_DIR}/*/journal_*.log

Recommended Analysis Workflow:
===============================

1. Check cluster quorum and node status:
   - Review pcs_status.txt on both nodes
   - Check crm_mon.txt for cluster state

2. Verify etcd health:
   - Compare etcd_member_list.txt between nodes
   - Review etcd_endpoint_health.txt and etcd_endpoint_status.txt
   - Check for cluster ID mismatches in cib_attributes.txt

3. Analyze resource state:
   - Check pcs_resource_status.txt for failed resources
   - Review podman_ps.txt to see if etcd containers are running
   - Examine podman_logs.txt for container errors

4. Review system logs for error patterns:
   - Search journal_pacemaker.log for fencing/resource failures
   - Check journal_corosync.log for quorum issues
   - Examine journal_etcd.log for etcd-specific errors

5. Check OpenShift integration:
   - Review etcd_operator.yaml for degraded conditions
   - Check degraded_operators.txt for related issues
   - Examine etcd_events.txt for recent problems

For assistance with analysis, refer to:
- .claude/commands/etcd/TROUBLESHOOTING_SKILL.md
- .claude/commands/etcd/pacemaker/Pacemaker_Administration/troubleshooting.rst
- Use slash commands like /etcd:etcd-ops-guide:failures
EOF

info "Diagnostic collection completed successfully"
echo ""
section "Summary"
echo "Output Directory: ${OUTPUT_DIR}"
echo ""
echo "View the diagnostic report:"
echo "  cat ${OUTPUT_DIR}/DIAGNOSTIC_REPORT.txt"
echo ""
echo "To analyze the collected data, review files in:"
echo "  ${OUTPUT_DIR}/"
