#!/usr/bin/bash
#
# Configuration preflight for the two-node-toolbox deployment flow.
# Read-only: validates required tools, SSH keys, Ansible collections, and all
# configuration files, printing a concrete fix command for every failure.
# Changes no state and is safe to run at any time.
#
# Usage: doctor.sh [cluster-type...]
#   With no arguments, runs common checks plus every auto-detected section.
#   With cluster types (e.g. fencing-kcli), the named method's section becomes
#   mandatory and its method-specific warnings are promoted to failures.
#
# Exits non-zero if and only if any check FAILed.

SCRIPT_DIR=$(dirname "$0")
DEPLOY_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"

REPO_ROOT="$(cd "${DEPLOY_DIR}/.." && pwd)"
CONFIG_DIR="${REPO_ROOT}/config"
INSTANCE_ENV="${DEPLOY_DIR}/aws-hypervisor/instance.env"

# Suppress the generic instance.env warning from common.sh — doctor has its
# own instance.env section with better guidance.
export SKIP_INSTANCE_ENV_WARNING=1
# shellcheck source=/dev/null
source "${DEPLOY_DIR}/common.sh"

# Strict flags only after common.sh: it expands variables that may be unset.
# No 'set -e': a failing check must report and let the remaining checks run.
set -uo pipefail

readonly COLOR_GREEN='\033[0;32m'

PASS_COUNT=0
WARN_COUNT=0
FAIL_COUNT=0

# check_pass/check_warn/check_fail take the finding plus an optional fix hint
check_pass() {
  printf '%b[PASS]%b %s\n' "${COLOR_GREEN}" "${COLOR_CLEAR:-}" "$1"
  PASS_COUNT=$((PASS_COUNT + 1))
}

check_warn() {
  printf '%b[WARN]%b %s\n' "${COLOR_YELLOW:-}" "${COLOR_CLEAR:-}" "$1"
  if [[ $# -gt 1 ]]; then
    printf '       fix: %s\n' "$2"
  fi
  WARN_COUNT=$((WARN_COUNT + 1))
}

check_fail() {
  printf '%b[FAIL]%b %s\n' "${COLOR_RED:-}" "${COLOR_CLEAR:-}" "$1"
  if [[ $# -gt 1 ]]; then
    printf '       fix: %s\n' "$2"
  fi
  FAIL_COUNT=$((FAIL_COUNT + 1))
}

check_note() {
  printf '%b[NOTE]%b %s\n' "${COLOR_BLUE:-}" "${COLOR_CLEAR:-}" "$1"
}

section() {
  printf '\n--- %s ---\n' "$1"
}

usage() {
  echo "Usage: $0 [--aws] [cluster-type...]"
  echo ""
  echo "Read-only configuration preflight. With no arguments, runs common checks"
  echo "plus every auto-detected section. Naming a cluster type makes its"
  echo "deployment method's checks mandatory."
  echo ""
  echo "Options:"
  echo "  --aws    Require instance.env (promotes missing instance.env to FAIL)"
  echo ""
  echo "Valid cluster types: fencing-ipi fencing-agent fencing-assisted"
  echo "                     fencing-kcli arbiter-ipi arbiter-agent arbiter-kcli"
  echo "                     sno-ipi sno-agent"
}

# --- Argument parsing (targeted mode) ---

TARGETED=0
NEED_DEVSCRIPTS=0
NEED_KCLI=0
NEED_ASSISTED=0
NEED_AWS=0
REQUIRED_TOPOLOGIES=" "
TARGETED_TYPES=""

for arg in "$@"; do
  case "${arg}" in
    -h|--help)
      usage
      exit 0
      ;;
    --aws)
      NEED_AWS=1
      ;;
    fencing-assisted)
      # assisted deploys the hub via fencing-ipi, so it needs the dev-scripts config
      TARGETED=1
      NEED_DEVSCRIPTS=1
      NEED_ASSISTED=1
      REQUIRED_TOPOLOGIES+="fencing "
      TARGETED_TYPES+=" ${arg}"
      ;;
    arbiter-ipi|arbiter-agent|fencing-ipi|fencing-agent|sno-ipi|sno-agent)
      TARGETED=1
      NEED_DEVSCRIPTS=1
      REQUIRED_TOPOLOGIES+="${arg%-*} "
      TARGETED_TYPES+=" ${arg}"
      ;;
    arbiter-kcli|fencing-kcli)
      TARGETED=1
      NEED_KCLI=1
      TARGETED_TYPES+=" ${arg}"
      ;;
    *)
      echo "Error: Unknown cluster type: '${arg}'"
      usage
      exit 2
      ;;
  esac
done

topology_required() {
  [[ "${REQUIRED_TOPOLOGIES}" == *" $1 "* ]]
}

tool_hint() {
  case "$1" in
    aws) echo "install the AWS CLI: https://docs.aws.amazon.com/cli/" ;;
    ansible-playbook) echo "install Ansible (e.g. 'dnf install ansible-core' or 'pip install ansible')" ;;
    go) echo "install Go: https://go.dev/dl/ (package 'golang' on Fedora/RHEL)" ;;
    *) echo "install '$1' with your package manager" ;;
  esac
}

echo "two-node-toolbox configuration preflight (read-only)"
if [[ "${TARGETED}" -eq 1 ]]; then
  check_note "validating strictly for:${TARGETED_TYPES}"
fi
if [[ "${NEED_AWS}" -eq 1 ]]; then
  check_note "AWS mode: instance.env is required"
fi

# --- Required tools ---

section "Required tools"

MISSING_TOOLS=""
for tool in make aws jq rsync ansible-playbook go; do
  if ! command -v "${tool}" >/dev/null 2>&1; then
    check_fail "required tool '${tool}' not found on PATH" "$(tool_hint "${tool}")"
    MISSING_TOOLS+="${tool} "
  fi
done
if [[ -z "${MISSING_TOOLS}" ]]; then
  check_pass "required tools present (make aws jq rsync ansible-playbook go)"
fi

if command -v timeout >/dev/null 2>&1; then
  check_pass "'timeout' present"
else
  check_warn "'timeout' not found on PATH" "on macOS install coreutils: 'brew install coreutils'"
fi

# --- SSH key ---

section "SSH key"

if [[ -n "${SSH_PUBLIC_KEY:-}" ]]; then
  if [[ -f "${SSH_PUBLIC_KEY}" ]]; then
    check_pass "SSH public key found (SSH_PUBLIC_KEY=${SSH_PUBLIC_KEY})"
  else
    check_fail "SSH_PUBLIC_KEY in instance.env points to a missing file: ${SSH_PUBLIC_KEY}" \
      "fix the path in ${CONFIG_DIR}/instance.env, or generate a key: 'ssh-keygen -t ed25519 -f ~/.ssh/id_ed25519'"
  fi
elif [[ -f "${HOME}/.ssh/id_ed25519.pub" ]]; then
  check_pass "SSH public key found (~/.ssh/id_ed25519.pub)"
else
  FOUND_KEY=""
  for key in "${HOME}"/.ssh/id_*.pub; do
    if [[ -f "${key}" ]]; then
      FOUND_KEY="${key}"
      break
    fi
  done
  if [[ -n "${FOUND_KEY}" ]]; then
    check_pass "SSH public key found (${FOUND_KEY})"
  else
    check_warn "no SSH public key found in ~/.ssh" \
      "generate one: 'ssh-keygen -t ed25519 -f ~/.ssh/id_ed25519'"
  fi
fi

# --- Ansible collections ---

section "Ansible collections"

REQUIREMENTS_FILE="${DEPLOY_DIR}/openshift-clusters/collections/requirements.yml"
if ! command -v ansible-galaxy >/dev/null 2>&1; then
  check_warn "collection check skipped: 'ansible-galaxy' not found on PATH" "$(tool_hint ansible-playbook)"
else
  if ! INSTALLED_COLLECTIONS="$(ansible-galaxy collection list 2>&1)"; then
    check_warn "ansible-galaxy collection list failed; collection check unreliable" \
      "run 'ansible-galaxy collection list' manually to diagnose"
  fi
  MISSING_COLLECTIONS=""
  while read -r name; do
    [[ -z "${name}" ]] && continue
    if ! grep -Eq "^${name//./\\.}[[:space:]]" <<<"${INSTALLED_COLLECTIONS}"; then
      MISSING_COLLECTIONS+="${name} "
    fi
  done < <(awk '/^[[:space:]]*- name:/ {print $3}' "${REQUIREMENTS_FILE}")
  if [[ -z "${MISSING_COLLECTIONS}" ]]; then
    check_pass "all Ansible collections from collections/requirements.yml installed"
  else
    check_fail "missing Ansible collections: ${MISSING_COLLECTIONS% }" \
      "ansible-galaxy collection install -r ${REQUIREMENTS_FILE}"
  fi
fi

# --- Inventory ---

section "Inventory"

INVENTORY="${DEPLOY_DIR}/openshift-clusters/inventory.ini"
INVENTORY_SAMPLE="${INVENTORY}.sample"
if [[ ! -f "${INVENTORY}" ]]; then
  # Not required until an OpenShift deployment: 'make deploy <type>' generates
  # it in the AWS flow, so absence is informational even in targeted mode.
  check_note "inventory.ini not created yet - run 'make inventory' after creating an AWS instance ('make deploy <type>' generates it automatically), or copy inventory.ini.sample and edit it for an external host"
elif cmp -s "${INVENTORY}" "${INVENTORY_SAMPLE}"; then
  check_fail "inventory.ini is an unedited copy of inventory.ini.sample" \
    "edit ${INVENTORY} with your host IP and SSH user, or run 'make inventory' to fill it from the current AWS instance"
elif ! grep -q '^\[metal_machine\]' "${INVENTORY}"; then
  check_fail "inventory.ini has no [metal_machine] section" \
    "restore the [metal_machine] group (see inventory.ini.sample), or run 'make inventory'"
else
  check_pass "inventory.ini present and edited"
fi

# --- AWS hypervisor ---

section "AWS hypervisor (instance.env)"

if [[ ! -f "${INSTANCE_ENV}" ]]; then
  if [[ "${NEED_AWS}" -eq 1 ]]; then
    check_fail "instance.env missing (required for AWS deployment)" \
      "cp ${CONFIG_DIR}/instance.env.template ${CONFIG_DIR}/instance.env && edit it, then run 'make sync-config'"
  else
    check_note "section skipped: instance.env not found (only needed for the AWS hypervisor flow) - to use it: 'cp ${CONFIG_DIR}/instance.env.template ${CONFIG_DIR}/instance.env' and edit"
  fi
else
  # set +u: the deployment scripts never source instance.env under nounset,
  # so the probe must not be stricter than real usage
  # shellcheck source=/dev/null
  if SOURCE_ERR=$( (set -e; set +u; source "${INSTANCE_ENV}") 2>&1 >/dev/null ); then
    check_pass "instance.env sources cleanly"
  else
    check_fail "instance.env does not source cleanly: ${SOURCE_ERR}" \
      "fix the shell syntax in ${CONFIG_DIR}/instance.env"
  fi

  if [[ -n "${REGION:-}" && -n "${AWS_PROFILE:-}" ]]; then
    check_pass "REGION (${REGION}) and AWS_PROFILE (${AWS_PROFILE}) are set"
  else
    check_fail "REGION and/or AWS_PROFILE not set by instance.env" \
      "set REGION and AWS_PROFILE in ${CONFIG_DIR}/instance.env (see ${CONFIG_DIR}/instance.env.template)"
  fi

  if ! command -v aws >/dev/null 2>&1 || ! command -v timeout >/dev/null 2>&1; then
    check_warn "AWS credential check skipped ('aws' and 'timeout' must be on PATH)"
  else
    AWS_ERR="$(timeout 15 aws sts get-caller-identity --output json --no-cli-pager 2>&1 >/dev/null)"
    AWS_RC=$?
    if [[ ${AWS_RC} -eq 0 ]]; then
      check_pass "AWS credentials are live (sts get-caller-identity succeeded)"
    elif [[ ${AWS_RC} -eq 124 ]]; then
      check_warn "AWS credential check timed out after 15s" "check network/VPN connectivity and retry"
    elif [[ ${AWS_RC} -ge 125 ]]; then
      check_warn "AWS credential check could not run (exit ${AWS_RC})"
    else
      check_fail "AWS credentials not working: $(head -1 <<<"${AWS_ERR}")" \
        "log in again (e.g. 'aws sso login --profile ${AWS_PROFILE:-<profile>}') or check 'aws configure list'"
    fi
  fi
fi

# --- dev-scripts configuration ---

section "dev-scripts configuration"

DS_FILES_DIR="${DEPLOY_DIR}/openshift-clusters/roles/dev-scripts/install-dev/files"
DS_PULL_SECRET="${DS_FILES_DIR}/pull-secret.json"

DS_PULL_SECRET_OK=0
if [[ -f "${DS_PULL_SECRET}" ]]; then
  if ! command -v jq >/dev/null 2>&1; then
    check_warn "pull-secret.json JSON check skipped: 'jq' not found on PATH"
  elif jq . "${DS_PULL_SECRET}" >/dev/null 2>&1; then
    check_pass "pull-secret.json present and valid JSON (dev-scripts)"
    DS_PULL_SECRET_OK=1
  else
    check_fail "pull-secret.json is not valid JSON (dev-scripts)" \
      "re-download it from https://cloud.redhat.com/openshift/install/pull-secret and save it to ${CONFIG_DIR}/pull-secret.json"
  fi
elif [[ "${NEED_DEVSCRIPTS}" -eq 1 ]]; then
  check_fail "pull-secret.json missing (required for the requested dev-scripts deployment)" \
    "download it from https://cloud.redhat.com/openshift/install/pull-secret and save it to ${CONFIG_DIR}/pull-secret.json"
else
  check_warn "pull-secret.json missing (needed for dev-scripts deployments)" \
    "download it from https://cloud.redhat.com/openshift/install/pull-secret and save it to ${CONFIG_DIR}/pull-secret.json"
fi

for topology in arbiter fencing sno; do
  CONFIG_FILE="${DS_FILES_DIR}/config_${topology}.sh"
  if [[ ! -f "${CONFIG_FILE}" ]]; then
    if topology_required "${topology}"; then
      check_fail "config_${topology}.sh missing (required for the requested deployment)" \
        "cp ${CONFIG_DIR}/config_${topology}_example.sh ${CONFIG_DIR}/config_${topology}.sh and set OPENSHIFT_RELEASE_IMAGE / CI_TOKEN"
    else
      check_warn "config_${topology}.sh missing (only needed to deploy the ${topology} topology with dev-scripts)" \
        "cp ${CONFIG_DIR}/config_${topology}_example.sh ${CONFIG_DIR}/config_${topology}.sh and set OPENSHIFT_RELEASE_IMAGE / CI_TOKEN"
    fi
    continue
  fi
  check_pass "config_${topology}.sh present"

  # CI registry cross-check: a config that pulls from the CI registry needs a
  # matching auth entry in the pull secret (same rule as install-dev/tasks/config.yml)
  if grep -q 'registry.ci.openshift.org' "${CONFIG_FILE}" && [[ ${DS_PULL_SECRET_OK} -eq 1 ]]; then
    if jq -e '.auths | has("registry.ci.openshift.org")' "${DS_PULL_SECRET}" >/dev/null 2>&1; then
      check_pass "pull secret has registry.ci.openshift.org auth (used by config_${topology}.sh)"
    else
      check_fail "config_${topology}.sh uses registry.ci.openshift.org but the pull secret has no auth entry for it" \
        "add CI registry credentials to ${CONFIG_DIR}/pull-secret.json, or switch to a public release image (quay.io/openshift-release-dev/ocp-release)"
    fi
  fi

  # CI token registry check: only when CI_TOKEN is set and the release image
  # is on the CI registry (same condition as install-dev/tasks/config.yml)
  CI_TOKEN="$(sed -nE 's/^export CI_TOKEN="([^"]+)".*/\1/p' "${CONFIG_FILE}" | head -1)"
  RELEASE_REGISTRY="$(sed -nE 's|^export OPENSHIFT_RELEASE_IMAGE="?([^/"]+).*|\1|p' "${CONFIG_FILE}" | head -1)"
  if [[ -n "${CI_TOKEN}" && "${RELEASE_REGISTRY}" == "registry.ci.openshift.org" ]]; then
    if ! command -v curl >/dev/null 2>&1; then
      check_warn "CI token check skipped: 'curl' not found on PATH"
    else
      HTTP_CODE="$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 \
        -H "Authorization: Bearer ${CI_TOKEN}" "https://${RELEASE_REGISTRY}/v2/")"
      CURL_RC=$?
      if [[ ${CURL_RC} -ne 0 ]]; then
        check_warn "CI token check: curl failed (exit ${CURL_RC}) reaching ${RELEASE_REGISTRY}"
      elif [[ "${HTTP_CODE}" == "401" ]]; then
        check_fail "CI token in config_${topology}.sh is invalid or expired (HTTP 401 from ${RELEASE_REGISTRY})" \
          "update CI_TOKEN in ${CONFIG_DIR}/config_${topology}.sh (copy a fresh token from the CI cluster console)"
      elif [[ "${HTTP_CODE}" == "200" ]]; then
        check_pass "CI token in config_${topology}.sh accepted by ${RELEASE_REGISTRY}"
      else
        check_warn "CI token check: unexpected HTTP ${HTTP_CODE} from ${RELEASE_REGISTRY}"
      fi
    fi
  fi

  if [[ -n "${CI_TOKEN}" ]]; then
    CI_SERVER="api.ci.l2s4.p1.openshiftapps.com"
    if ! command -v curl >/dev/null 2>&1; then
      check_warn "CI API token check skipped: 'curl' not found on PATH"
    else
      HTTP_CODE="$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 \
        -H "Authorization: Bearer ${CI_TOKEN}" \
        "https://${CI_SERVER}:6443/apis/user.openshift.io/v1/users/~")"
      CURL_RC=$?
      if [[ ${CURL_RC} -ne 0 ]]; then
        check_warn "CI API token check: curl failed (exit ${CURL_RC}) reaching ${CI_SERVER}"
      elif [[ "${HTTP_CODE}" == "401" ]]; then
        check_fail "CI token in config_${topology}.sh is expired against the CI cluster API (${CI_SERVER})" \
          "log in at https://console-openshift-console.apps.ci.l2s4.p1.openshiftapps.com/, copy a fresh token, update CI_TOKEN in ${CONFIG_DIR}/config_${topology}.sh"
      elif [[ "${HTTP_CODE}" == "200" ]]; then
        check_pass "CI token in config_${topology}.sh accepted by CI cluster API (${CI_SERVER})"
      else
        check_warn "CI API token check: unexpected HTTP ${HTTP_CODE} from ${CI_SERVER}"
      fi
    fi
  fi
done

# --- kcli configuration ---

section "kcli configuration"

KCLI_PULL_SECRET="${DEPLOY_DIR}/openshift-clusters/roles/kcli/kcli-install/files/pull-secret.json"
KCLI_VARS="${DEPLOY_DIR}/openshift-clusters/vars/kcli.yml"

if [[ "${NEED_KCLI}" -eq 0 && ! -f "${KCLI_PULL_SECRET}" && ! -f "${KCLI_VARS}" ]]; then
  check_note "section skipped: no kcli configuration detected (vars/kcli.yml or kcli pull secret) - only needed for *-kcli deployments"
else
  if [[ -f "${KCLI_PULL_SECRET}" ]]; then
    if ! command -v jq >/dev/null 2>&1; then
      check_warn "kcli pull-secret.json JSON check skipped: 'jq' not found on PATH"
    elif jq . "${KCLI_PULL_SECRET}" >/dev/null 2>&1; then
      check_pass "pull-secret.json present and valid JSON (kcli)"
    else
      check_fail "pull-secret.json is not valid JSON (kcli)" \
        "re-download it from https://cloud.redhat.com/openshift/install/pull-secret and save it to ${CONFIG_DIR}/pull-secret.json"
    fi
    if [[ -f "${DS_PULL_SECRET}" ]] && ! cmp -s "${KCLI_PULL_SECRET}" "${DS_PULL_SECRET}"; then
      check_warn "kcli pull-secret.json differs from the dev-scripts copy" \
        "save the correct version to ${CONFIG_DIR}/pull-secret.json and run 'make sync-config' to update both locations"
    fi
  elif [[ "${NEED_KCLI}" -eq 1 ]]; then
    check_fail "pull-secret.json missing (required for the requested kcli deployment)" \
      "download it from https://cloud.redhat.com/openshift/install/pull-secret and save it to ${CONFIG_DIR}/pull-secret.json"
  else
    check_warn "pull-secret.json missing (needed for *-kcli deployments)" \
      "download it from https://cloud.redhat.com/openshift/install/pull-secret and save it to ${CONFIG_DIR}/pull-secret.json"
  fi
fi

# --- assisted installer configuration ---

section "assisted installer configuration"

ASSISTED_VARS="${DEPLOY_DIR}/openshift-clusters/vars/assisted.yml"

if [[ "${NEED_ASSISTED}" -eq 0 && ! -f "${ASSISTED_VARS}" ]]; then
  check_note "section skipped: no assisted config detected (vars/assisted.yml) - only needed for fencing-assisted deployments"
else
  if [[ -f "${ASSISTED_VARS}" ]]; then
    check_pass "vars/assisted.yml present"
    SPOKE_NAME="$(sed -nE 's/^spoke_cluster_name:[[:space:]]*"?([^"]+)"?.*/\1/p' "${ASSISTED_VARS}" | head -1)"
    if [[ -n "${SPOKE_NAME}" ]]; then
      check_pass "spoke_cluster_name set to '${SPOKE_NAME}'"
    else
      check_warn "spoke_cluster_name not set in vars/assisted.yml (defaults to 'spoke-tnf')"
    fi
  elif [[ "${NEED_ASSISTED}" -eq 1 ]]; then
    check_fail "vars/assisted.yml missing (required for fencing-assisted deployment)" \
      "cp ${CONFIG_DIR}/assisted.yml.template ${CONFIG_DIR}/assisted.yml and edit it"
  fi
fi

# --- Summary ---

echo ""
echo "Summary: ${PASS_COUNT} passed, ${WARN_COUNT} warnings, ${FAIL_COUNT} failures"
if [[ ${FAIL_COUNT} -gt 0 ]]; then
  printf '%b%s%b\n' "${COLOR_RED:-}" "ERROR: configuration is not ready - address the FAIL items above" "${COLOR_CLEAR:-}" >&2
  exit 1
fi
exit 0
