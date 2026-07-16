#!/usr/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

readonly COLOR_RED='\033[0;31m'
readonly COLOR_YELLOW='\033[0;33m'
readonly COLOR_GREEN='\033[0;32m'
readonly COLOR_BLUE='\033[0;34m'
readonly COLOR_CLEAR='\033[0m'

msg_err()  { echo -e "${COLOR_RED}ERROR: ${1}${COLOR_CLEAR}" >&2; }
msg_ok()   { echo -e "${COLOR_GREEN}OK: ${1}${COLOR_CLEAR}" >&2; }
msg_info() { echo -e "${COLOR_BLUE}INFO: ${1}${COLOR_CLEAR}" >&2; }
msg_warn() { echo -e "${COLOR_YELLOW}WARN: ${1}${COLOR_CLEAR}" >&2; }

# Files to sync and their canonical (non-config/) locations in the main
# checkout. For each file the script picks the newer of config/<name> and
# the canonical path, then copies it into the worktree's config/ folder.
#
# Format: config-filename:canonical-path (relative to repo root)
WORKTREE_SYNC_FILES=(
  "pull-secret.json:deploy/openshift-clusters/roles/dev-scripts/install-dev/files/pull-secret.json"
  "instance.env:deploy/aws-hypervisor/instance.env"
  "config_arbiter.sh:deploy/openshift-clusters/roles/dev-scripts/install-dev/files/config_arbiter.sh"
  "config_fencing.sh:deploy/openshift-clusters/roles/dev-scripts/install-dev/files/config_fencing.sh"
  "config_sno.sh:deploy/openshift-clusters/roles/dev-scripts/install-dev/files/config_sno.sh"
)

# ---------------------------------------------------------------------------

GIT_DIR="$(git -C "${REPO_ROOT}" rev-parse --git-dir 2>/dev/null)"
GIT_COMMON="$(git -C "${REPO_ROOT}" rev-parse --git-common-dir 2>/dev/null)"

if [[ "${GIT_DIR}" == "${GIT_COMMON}" ]]; then
  msg_info "Not a worktree — nothing to sync"
  exit 0
fi

MAIN_CHECKOUT="$(git -C "${REPO_ROOT}" worktree list --porcelain | head -1 | sed 's/^worktree //')"

if [[ ! -d "${MAIN_CHECKOUT}/config" ]]; then
  msg_err "Main checkout config/ not found at ${MAIN_CHECKOUT}/config"
  exit 1
fi

# Pick the newer of two files. Prints the path of the winner, or nothing if
# neither exists.
newer_of() {
  local a="$1" b="$2"
  if [[ -f "$a" && -f "$b" ]]; then
    if [[ "$a" -nt "$b" ]]; then echo "$a"; else echo "$b"; fi
  elif [[ -f "$a" ]]; then
    echo "$a"
  elif [[ -f "$b" ]]; then
    echo "$b"
  fi
}

COPIED=()

for entry in "${WORKTREE_SYNC_FILES[@]}"; do
  name="${entry%%:*}"
  canonical="${entry#*:}"
  dest="${REPO_ROOT}/config/${name}"

  [[ -f "$dest" ]] && continue

  src="$(newer_of "${MAIN_CHECKOUT}/config/${name}" "${MAIN_CHECKOUT}/${canonical}")"
  [[ -n "$src" ]] || continue

  cp -p "$src" "$dest"
  COPIED+=("$name")
done

if [[ ${#COPIED[@]} -gt 0 ]]; then
  IFS=', ' msg_ok "Copied from main checkout: ${COPIED[*]}"
else
  msg_info "Worktree config/ already up to date"
fi
