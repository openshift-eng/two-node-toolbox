#!/usr/bin/bash
set -euo pipefail

SCRIPT_NAME="$(basename "$0")"
readonly SCRIPT_NAME
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIR
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
readonly REPO_ROOT

readonly DEFAULT_METAL3_TAG="2026-06"

readonly COLOR_RED='\033[0;31m'
readonly COLOR_YELLOW='\033[0;33m'
readonly COLOR_GREEN='\033[0;32m'
readonly COLOR_BLUE='\033[0;34m'
readonly COLOR_CLEAR='\033[0m'

msg_err()  { echo -e "${COLOR_RED}ERROR: ${1}${COLOR_CLEAR}" >&2; }
msg_warn() { echo -e "${COLOR_YELLOW}WARN: ${1}${COLOR_CLEAR}" >&2; }
msg_ok()   { echo -e "${COLOR_GREEN}OK: ${1}${COLOR_CLEAR}" >&2; }
msg_info() { echo -e "${COLOR_BLUE}INFO: ${1}${COLOR_CLEAR}" >&2; }

valreq() { [[ -n "${2-}" && "$2" != -* ]]; }

# ---------------------------------------------------------------------------
# Config transform
# ---------------------------------------------------------------------------

transform_config() {
    local tmpfile="$1" release_image="$2" ip_stack="$3" ci_token="$4"
    local scenario="$5" arch="$6" metal3_tag="$7"

    sed -i "s|^export OPENSHIFT_RELEASE_IMAGE=.*|export OPENSHIFT_RELEASE_IMAGE=${release_image}|" "$tmpfile"

    sed -i "s|^export IP_STACK=\".*\"|export IP_STACK=\"${ip_stack}\"|" "$tmpfile"

    if grep -q '^export AGENT_E2E_TEST_SCENARIO=' "$tmpfile"; then
        sed -i "s|^export AGENT_E2E_TEST_SCENARIO=.*|export AGENT_E2E_TEST_SCENARIO=\"${scenario}\"|" "$tmpfile"
    elif grep -q '^# *export AGENT_E2E_TEST_SCENARIO=' "$tmpfile"; then
        sed -i "s|^# *export AGENT_E2E_TEST_SCENARIO=.*|export AGENT_E2E_TEST_SCENARIO=\"${scenario}\"|" "$tmpfile"
    fi

    if grep -q '^export CI_TOKEN=' "$tmpfile"; then
        sed -i "s|^export CI_TOKEN=.*|export CI_TOKEN=\"${ci_token}\"|" "$tmpfile"
    else
        sed -i "/^export OPENSHIFT_RELEASE_IMAGE=/a export CI_TOKEN=\"${ci_token}\"" "$tmpfile"
    fi

    sed -i 's|^export OPENSHIFT_CI="true"|# export OPENSHIFT_CI="true"|' "$tmpfile"

    if [[ "$arch" == "aarch64" ]]; then
        # shellcheck disable=SC2016
        if grep -q '^# *if \[ "\$(uname -m)" = "aarch64" \]' "$tmpfile"; then
            # shellcheck disable=SC2016
            sed -i '/^# *if \[ "\$(uname -m)" = "aarch64" \]/,/^# *fi/{s/^# //}' "$tmpfile"
        else
            cat >> "$tmpfile" <<METAL3

# aarch64 (Graviton) Metal3 image overrides — upstream images are x86_64-only.
# Rebuild monthly with: helpers/build-metal3-arm64.sh
if [ "\$(uname -m)" = "aarch64" ]; then
    export IRONIC_IMAGE=quay.io/rh-edge-enablement/ironic:${metal3_tag}
    export VBMC_IMAGE=quay.io/rh-edge-enablement/vbmc:${metal3_tag}
    export SUSHY_TOOLS_IMAGE=quay.io/rh-edge-enablement/sushy-tools:${metal3_tag}
fi
METAL3
        fi
        sed -i '/IRONIC_IMAGE\|VBMC_IMAGE\|SUSHY_TOOLS_IMAGE/s|:[0-9]\{4\}-[0-9]\{2\}|:'"${metal3_tag}"'|g' "$tmpfile"
    fi
}

# ---------------------------------------------------------------------------
# Self-check (drift armor)
# ---------------------------------------------------------------------------

self_check() {
    local file="$1" topology="$2"
    local ok=true

    local scenario
    scenario=$(grep -oP '^export AGENT_E2E_TEST_SCENARIO="\K[^"]+' "$file" || true)
    if [[ -z "$scenario" ]]; then
        msg_err "Self-check: missing AGENT_E2E_TEST_SCENARIO"
        ok=false
    else
        local prefix="${scenario%%_*}"
        local expected
        case "$topology" in
            arbiter) expected="TNA" ;;
            fencing) expected="TNF" ;;
            sno)     expected="SNO" ;;
        esac
        if [[ "$prefix" != "$expected" ]]; then
            msg_err "Self-check: scenario prefix '${prefix}' != expected '${expected}'"
            ok=false
        fi
    fi

    if ! grep -q '^export CI_TOKEN="' "$file"; then
        msg_err "Self-check: missing active CI_TOKEN"
        ok=false
    fi

    if grep -q '<PASTE' "$file"; then
        msg_err "Self-check: <PASTE placeholder survived"
        ok=false
    fi

    if grep -q '^export OPENSHIFT_CI=' "$file"; then
        msg_err "Self-check: OPENSHIFT_CI still active (should be commented)"
        ok=false
    fi

    if ! bash -n "$file" 2>/dev/null; then
        msg_err "Self-check: bash syntax error"
        ok=false
    fi

    # shellcheck disable=SC1090
    if ! ( source "$file" ) 2>/dev/null; then
        msg_err "Self-check: file cannot be sourced"
        ok=false
    fi

    $ok
}

# ---------------------------------------------------------------------------
# Inventory handling
# ---------------------------------------------------------------------------

upsert_ini_var() {
    local file="$1" key="$2" value="$3"
    if grep -q "^${key}=" "$file"; then
        sed -i "s|^${key}=.*|${key}=${value}|" "$file"
    else
        sed -i "/^\[metal_machine:vars\]/a ${key}=${value}" "$file"
    fi
}

handle_inventory() {
    local inventory="$1" ds_repo="$2" ds_branch="$3"

    if [[ -n "$ds_repo" ]]; then
        [[ -f "$inventory" ]] || {
            msg_err "Inventory not found: ${inventory}"
            msg_err "  Run /setup or 'make inventory' first"
            return 1
        }
        [[ -n "$ds_branch" ]] || ds_branch="master"
        upsert_ini_var "$inventory" "dev_scripts_src_repo" "$ds_repo"
        upsert_ini_var "$inventory" "dev_scripts_branch" "$ds_branch"
        msg_info "Set dev-scripts fork: repo=${ds_repo} branch=${ds_branch}"
    elif [[ -f "$inventory" ]]; then
        local removed=0
        if grep -q '^dev_scripts_src_repo=' "$inventory"; then
            sed -i '/^dev_scripts_src_repo=/d' "$inventory"
            removed=1
        fi
        if grep -q '^dev_scripts_branch=' "$inventory"; then
            sed -i '/^dev_scripts_branch=/d' "$inventory"
            removed=1
        fi
        [[ "$removed" -eq 0 ]] || msg_info "Cleared dev-scripts fork override from inventory.ini"
    fi
}

# ---------------------------------------------------------------------------
# Usage
# ---------------------------------------------------------------------------

usage() {
    cat >&2 <<EOF
Generate a dev-scripts config file from the example template.

Usage:
    ${SCRIPT_NAME} --topology TOPO --method METHOD --release-image IMAGE \\
                   --ci-token TOKEN [OPTIONS]

Required:
    --topology TOPO         arbiter|tna, fencing|tnf, or sno
    --method METHOD         ipi or agent
    --release-image IMAGE   Fully resolved release image pullspec
    --ci-token TOKEN        CI bearer token (never echoed to stdout)

Options:
    --ip-stack STACK        v4, v6, or v4v6 (default: v4)
    --arch ARCH             x86_64 or aarch64 (default: x86_64)
    --metal3-tag TAG        aarch64 Metal3 image tag (default: ${DEFAULT_METAL3_TAG})
    --ds-repo URL           Dev-scripts fork repository URL
    --ds-branch BRANCH      Dev-scripts fork branch (requires --ds-repo)
    --inventory PATH        Inventory file path
    --output PATH           Output config path (default: config/config_<topology>.sh)
    --force                 Overwrite existing output (backs up to .bak)
    -h, --help              Show this help

Constraints:
    aarch64 + ip-stack != v4      Blocked (IPv6 unsupported on ARM)
    aarch64 + -multi image        Blocked (explicit aarch64 payload required)
    --ds-branch without --ds-repo Error

Exit codes:
    0   Config written (path on stdout)
    2   Usage error
    3   Constraint violation
    4   Output exists without --force
    5   Self-check failed
EOF
    exit "${1:-0}"
}

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------

TOPOLOGY=""
METHOD=""
RELEASE_IMAGE=""
CI_TOKEN_VALUE=""
IP_STACK="v4"
ARCH="x86_64"
METAL3_TAG="${DEFAULT_METAL3_TAG}"
DS_REPO=""
DS_BRANCH=""
INVENTORY=""
OUTPUT=""
FORCE="false"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --topology)
            valreq "$1" "${2-}" || { msg_err "--topology requires a value"; exit 2; }
            TOPOLOGY="$2"; shift 2 ;;
        --method)
            valreq "$1" "${2-}" || { msg_err "--method requires a value"; exit 2; }
            METHOD="$2"; shift 2 ;;
        --release-image)
            valreq "$1" "${2-}" || { msg_err "--release-image requires a value"; exit 2; }
            RELEASE_IMAGE="$2"; shift 2 ;;
        --ci-token)
            valreq "$1" "${2-}" || { msg_err "--ci-token requires a value"; exit 2; }
            CI_TOKEN_VALUE="$2"; shift 2 ;;
        --ip-stack)
            valreq "$1" "${2-}" || { msg_err "--ip-stack requires a value"; exit 2; }
            IP_STACK="$2"; shift 2 ;;
        --arch)
            valreq "$1" "${2-}" || { msg_err "--arch requires a value"; exit 2; }
            ARCH="$2"; shift 2 ;;
        --metal3-tag)
            valreq "$1" "${2-}" || { msg_err "--metal3-tag requires a value"; exit 2; }
            METAL3_TAG="$2"; shift 2 ;;
        --ds-repo)
            valreq "$1" "${2-}" || { msg_err "--ds-repo requires a value"; exit 2; }
            DS_REPO="$2"; shift 2 ;;
        --ds-branch)
            valreq "$1" "${2-}" || { msg_err "--ds-branch requires a value"; exit 2; }
            DS_BRANCH="$2"; shift 2 ;;
        --inventory)
            valreq "$1" "${2-}" || { msg_err "--inventory requires a value"; exit 2; }
            INVENTORY="$2"; shift 2 ;;
        --output)
            valreq "$1" "${2-}" || { msg_err "--output requires a value"; exit 2; }
            OUTPUT="$2"; shift 2 ;;
        --force)
            FORCE="true"; shift ;;
        -h|--help)
            usage 0 ;;
        *)
            msg_err "Unknown option: $1"; usage 2 ;;
    esac
done

# ---------------------------------------------------------------------------
# Validation
# ---------------------------------------------------------------------------

case "$TOPOLOGY" in
    tna) TOPOLOGY="arbiter" ;;
    tnf) TOPOLOGY="fencing" ;;
    arbiter|fencing|sno) ;;
    "") msg_err "--topology is required"; exit 2 ;;
    *) msg_err "Invalid topology: ${TOPOLOGY} (expected: arbiter|tna, fencing|tnf, sno)"; exit 2 ;;
esac

[[ -n "$METHOD" ]]         || { msg_err "--method is required"; exit 2; }
[[ -n "$RELEASE_IMAGE" ]]  || { msg_err "--release-image is required"; exit 2; }
[[ -n "$CI_TOKEN_VALUE" ]] || { msg_err "--ci-token is required"; exit 2; }

case "$METHOD" in
    ipi|agent) ;;
    *) msg_err "Invalid method: ${METHOD} (expected: ipi, agent)"; exit 2 ;;
esac
case "$IP_STACK" in
    v4|v6|v4v6) ;;
    *) msg_err "Invalid ip-stack: ${IP_STACK} (expected: v4, v6, v4v6)"; exit 2 ;;
esac
case "$ARCH" in
    x86_64|aarch64) ;;
    *) msg_err "Invalid arch: ${ARCH} (expected: x86_64, aarch64)"; exit 2 ;;
esac

if [[ "$CI_TOKEN_VALUE" == *"<PASTE"* || "$CI_TOKEN_VALUE" == "placeholder" ]]; then
    msg_err "--ci-token contains a placeholder, not a real token"
    exit 2
fi

if [[ -n "$DS_BRANCH" && -z "$DS_REPO" ]]; then
    msg_err "--ds-branch requires --ds-repo (branch on upstream is ambiguous)"
    exit 2
fi

# --- Constraint matrix ---

if [[ "$ARCH" == "aarch64" && "$IP_STACK" != "v4" ]]; then
    msg_err "aarch64 does not support IPv6 or dual-stack (IP_STACK=${IP_STACK})"
    msg_err "  Use --ip-stack v4 with aarch64"
    exit 3
fi

if [[ "$ARCH" == "aarch64" && "$RELEASE_IMAGE" == *"-multi"* ]]; then
    msg_err "aarch64 requires an explicit aarch64 payload (not -multi)"
    msg_err "  Use resolve-release-image.sh --arch aarch64 to get the correct image"
    exit 3
fi

# ---------------------------------------------------------------------------
# Build scenario and paths
# ---------------------------------------------------------------------------

SCENARIO_PREFIX=""
case "$TOPOLOGY" in
    arbiter) SCENARIO_PREFIX="TNA" ;;
    fencing) SCENARIO_PREFIX="TNF" ;;
    sno)     SCENARIO_PREFIX="SNO" ;;
esac
IP_SUFFIX=""
case "$IP_STACK" in
    v4)   IP_SUFFIX="IPV4" ;;
    v6)   IP_SUFFIX="IPV6" ;;
    v4v6) IP_SUFFIX="IPV4V6" ;;
esac
SCENARIO="${SCENARIO_PREFIX}_${IP_SUFFIX}"

if [[ "$METHOD" == "agent" && "$IP_STACK" != "v4" ]]; then
    msg_warn "Agent scenario ${SCENARIO} must exist in dev-scripts' e2e scenario list"
fi

[[ -n "$INVENTORY" ]] || INVENTORY="${REPO_ROOT}/deploy/openshift-clusters/inventory.ini"
[[ -n "$OUTPUT" ]]    || OUTPUT="${REPO_ROOT}/config/config_${TOPOLOGY}.sh"

TEMPLATE="${REPO_ROOT}/config/config_${TOPOLOGY}_example.sh"
[[ -f "$TEMPLATE" ]] || { msg_err "Template not found: ${TEMPLATE}"; exit 2; }

# ---------------------------------------------------------------------------
# Check existing output
# ---------------------------------------------------------------------------

if [[ -f "$OUTPUT" ]]; then
    if [[ "$FORCE" != "true" ]]; then
        msg_err "Output file exists: ${OUTPUT}"
        msg_err "  Use --force to overwrite (backs up to .bak)"
        exit 4
    fi
    old_image=$(grep -oP '^export OPENSHIFT_RELEASE_IMAGE=\K.*' "$OUTPUT" 2>/dev/null || true)
    cp "$OUTPUT" "${OUTPUT}.bak"
    msg_info "Backed up existing config to ${OUTPUT}.bak"
    [[ -z "${old_image:-}" ]] || msg_info "Previous release image: ${old_image}"
fi

# ---------------------------------------------------------------------------
# Generate config
# ---------------------------------------------------------------------------

TMPFILE=$(mktemp)
trap 'rm -f "$TMPFILE"' EXIT

cp "$TEMPLATE" "$TMPFILE"
msg_info "Generating ${TOPOLOGY} config (${METHOD}, ${ARCH}, IP_STACK=${IP_STACK})"

transform_config "$TMPFILE" "$RELEASE_IMAGE" "$IP_STACK" "$CI_TOKEN_VALUE" \
    "$SCENARIO" "$ARCH" "$METAL3_TAG"

if ! self_check "$TMPFILE" "$TOPOLOGY"; then
    msg_err "Self-check failed; config not written"
    msg_err "  This likely indicates the example template has drifted from expected format"
    exit 5
fi

cp "$TMPFILE" "$OUTPUT"
msg_ok "Config written: ${OUTPUT}"
msg_info "Deploy targets auto-sync via make sync-config"

handle_inventory "$INVENTORY" "$DS_REPO" "$DS_BRANCH" || exit $?

echo "$OUTPUT"
