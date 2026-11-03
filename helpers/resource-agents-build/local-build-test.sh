#!/usr/bin/env bash
# Build resource-agents RPM on CentOS Stream 9 and 10 and tag in local registry.
# No push. Run from the helpers/resource-agents-build/ directory.
#
# Usage:
#   ./local-build-test.sh                                           # prompts for repo and ref
#   ./local-build-test.sh --repo https://github.com/myorg/resource-agents --ref my-branch
set -euo pipefail

DEFAULT_REPO="https://github.com/ClusterLabs/resource-agents"
DEFAULT_REF="main"

RESOURCE_AGENTS_REPO=""
RESOURCE_AGENTS_REF=""

usage() {
    echo "Usage: $0 [OPTIONS]"
    echo ""
    echo "Options:"
    echo "  --repo URL    Git repository URL (default: ${DEFAULT_REPO})"
    echo "  --ref REF     Git branch, tag, or commit (default: ${DEFAULT_REF})"
    echo "  -h, --help    Show this help"
    echo ""
    echo "If no options are provided, the script will prompt for values."
    echo "Press Enter at each prompt to use the default."
    exit "${1:-0}"
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --repo)
            if [[ -z "${2:-}" || "$2" == -* ]]; then
                echo "Error: --repo requires a value (RESOURCE_AGENTS_REPO)" >&2
                usage 1
            fi
            RESOURCE_AGENTS_REPO="$2"; shift 2 ;;
        --ref)
            if [[ -z "${2:-}" || "$2" == -* ]]; then
                echo "Error: --ref requires a value (RESOURCE_AGENTS_REF)" >&2
                usage 1
            fi
            RESOURCE_AGENTS_REF="$2"; shift 2 ;;
        -h|--help) usage ;;
        *) echo "Error: Unknown option: $1" >&2; usage 1 ;;
    esac
done

# If not provided via flags, prompt the user
if [[ -z "${RESOURCE_AGENTS_REPO}" ]]; then
    read -rp "Resource agents repo (Enter for default: ${DEFAULT_REPO}): " input
    RESOURCE_AGENTS_REPO="${input:-${DEFAULT_REPO}}"
fi
if [[ -z "${RESOURCE_AGENTS_REF}" ]]; then
    read -rp "Resource agents ref (Enter for default: ${DEFAULT_REF}): " input
    RESOURCE_AGENTS_REF="${input:-${DEFAULT_REF}}"
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "${SCRIPT_DIR}"

echo ""
echo "Building with:"
echo "  Repo: ${RESOURCE_AGENTS_REPO}"
echo "  Ref:  ${RESOURCE_AGENTS_REF}"
echo ""

echo "Building Stream 9 image..."
podman build -f Dockerfile.stream9 \
    --build-arg "RESOURCE_AGENTS_REPO=${RESOURCE_AGENTS_REPO}" \
    --build-arg "RESOURCE_AGENTS_REF=${RESOURCE_AGENTS_REF}" \
    -t localhost/tnf-resource-agents-build:stream9 .

echo "Building Stream 10 image..."
podman build -f Dockerfile.stream10 \
    --build-arg "RESOURCE_AGENTS_REPO=${RESOURCE_AGENTS_REPO}" \
    --build-arg "RESOURCE_AGENTS_REF=${RESOURCE_AGENTS_REF}" \
    -t localhost/tnf-resource-agents-build:stream10 .

echo "Done. Images in local store:"
podman images localhost/tnf-resource-agents-build --format "{{.Repository}}:{{.Tag}} {{.ID}}"
