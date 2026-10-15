#!/usr/bin/env bash
# OpenShift CLI wrapper with automatic proxy.env detection and handling
# This script ensures oc commands work whether cluster access is direct or requires proxy

set -euo pipefail

# Configuration
PROXY_ENV_PATH="${PROXY_ENV_PATH:-deploy/openshift-clusters/proxy.env}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

# Color codes for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Function to print colored messages
info() {
    echo -e "${GREEN}[INFO]${NC} $*" >&2
}

warn() {
    echo -e "${YELLOW}[WARN]${NC} $*" >&2
}

error() {
    echo -e "${RED}[ERROR]${NC} $*" >&2
}

# Change to repo root for consistent path resolution
cd "${REPO_ROOT}"

# Check if oc is available
if ! command -v oc &> /dev/null; then
    error "oc command not found in PATH"
    exit 1
fi

# Try direct access first
if oc version --request-timeout=5s &>/dev/null; then
    info "Direct cluster access available"
    exec oc "$@"
fi

# Direct access failed, check for proxy.env
if [ ! -f "${PROXY_ENV_PATH}" ]; then
    error "No direct cluster access and proxy.env not found at: ${PROXY_ENV_PATH}"
    error "Please ensure cluster is accessible or create proxy configuration"
    exit 1
fi

# Source proxy.env and retry
info "Direct access failed, sourcing proxy configuration: ${PROXY_ENV_PATH}"

# shellcheck disable=SC1090
source "${PROXY_ENV_PATH}"

# Verify proxy access works
if ! oc version --request-timeout=5s &>/dev/null; then
    error "Cluster access failed even with proxy configuration"
    error "Please verify proxy.env settings and cluster availability"
    exit 1
fi

info "Cluster access via proxy successful"

# Execute the oc command with all original arguments
exec oc "$@"
