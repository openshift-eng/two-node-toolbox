#!/usr/bin/bash
# Build and push operator images using profiles
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="${SCRIPT_DIR}/operators.conf"

# shellcheck source=/dev/null
source "${SCRIPT_DIR}/operator-config.sh"

# shellcheck source=/dev/null
. "$SCRIPT_DIR/profile.env"

# Default configuration (QUAY_NAMESPACE must be set in profile.env)
if [[ -z "${QUAY_NAMESPACE:-}" ]]; then
    echo "Error: QUAY_NAMESPACE not set. Please configure profile.env"
    exit 1
fi
DEFAULT_NAMESPACE="${QUAY_NAMESPACE}"
DEFAULT_TAG="${IMAGE_TAG:-latest}"
DEFAULT_AUTH_FILE="${REGISTRY_AUTH_FILE:-$HOME/.config/containers/auth.json}"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

usage() {
    cat <<EOF
Usage: $(basename "$0") [OPTIONS] OPERATOR [OPERATOR...]

Build and push operator images using predefined profiles.

OPERATORS:
  Specify operator aliases (e.g., cco, ceo) defined in operators.conf
  Optionally override branch: cco:my-branch

  Available operators (from operators.conf):
EOF
    grep '^\[' "$CONFIG_FILE" 2>/dev/null | sed 's/\[//;s/\]//' | sed 's/^/    /' || echo "    (none configured)"
    cat <<EOF

OPTIONS:
  -n, --namespace NAME    Registry namespace (default: ${DEFAULT_NAMESPACE})
  -t, --tag TAG          Image tag (default: ${DEFAULT_TAG})
  -v, --verbose          Show full build output (default: show last 10 lines)
  -h, --help             Show this help

EXAMPLES:
  # Build CCO from current branch
  $(basename "$0") cco

  # Build CCO and CEO
  $(basename "$0") cco ceo

  # Build CCO from specific branch
  $(basename "$0") cco:my-feature-branch

  # Build with custom tag
  $(basename "$0") -t v5.0-test cco

  # Build with verbose output
  $(basename "$0") -v cco

CONFIGURATION:
  Operators defined in: operators.conf

ENVIRONMENT VARIABLES:
  REGISTRY_AUTH_FILE     Path to pull secret (default: ~/.config/containers/auth.json)
  QUAY_NAMESPACE         Registry namespace override
  IMAGE_TAG              Image tag override

EOF
}

declare -a SUCCEEDED=()
declare -a FAILED=()

run_with_output() {
    local lines="$1"
    shift
    if [[ "$VERBOSE" == true ]]; then
        "$@" 2>&1
    else
        "$@" 2>&1 | tail -n "$lines"
    fi
}

check_registry_access() {
    local auth_file="$1"

    if [[ ! -f "$auth_file" ]]; then
        echo -e "${RED}✗ Registry auth file not found: ${auth_file}${NC}"
        echo "  Set REGISTRY_AUTH_FILE environment variable or create ~/pull-secret.json"
        return 1
    fi

    echo "Checking registry access..."
    echo "  Auth file: ${auth_file}"

    # Test pull access to CI registry
    if ! podman pull --authfile="${auth_file}" registry.ci.openshift.org/ocp/4.22:base-rhel9-minimal &>/dev/null; then
        echo -e "${RED}✗ Cannot pull from registry.ci.openshift.org${NC}"
        echo ""
        echo "To fix:"
        echo "  1. Login to CI cluster: https://console-openshift-console.apps.ci.l2s4.p1.openshiftapps.com"
        echo "  2. Run: podman login -u=\$(oc whoami) -p=\$(oc whoami -t) registry.ci.openshift.org --authfile=\$REGISTRY_AUTH_FILE"
        echo ""
        return 1
    fi

    echo -e "${GREEN}✓ Registry access verified${NC}"
    return 0
}

build_operator() {
    local operator_alias="$1"
    local branch_override="${2:-}"
    local namespace="$3"
    local tag="$4"
    local auth_file="$5"

    local operator_name repo_path dockerfile default_branch branch

    operator_name=$(get_config "$operator_alias" "name")
    repo_path=$(get_config "$operator_alias" "repo")
    dockerfile=$(get_config "$operator_alias" "dockerfile" "Dockerfile.ocp")
    # No fallback: an unset default_branch means "build whatever is checked out".
    default_branch=$(get_config "$operator_alias" "default_branch")

    if [[ -z "$operator_name" ]] || [[ -z "$repo_path" ]]; then
        echo -e "${RED}✗ Unknown operator: ${operator_alias}${NC}"
        echo "  Available: $(grep '^\[' "$CONFIG_FILE" | sed 's/\[//;s/\]//' | tr '\n' ' ')"
        FAILED+=("${operator_alias}: unknown operator")
        return 1
    fi

    local image_ref="${namespace}/${operator_name}:${tag}"

    echo -e "${YELLOW}Building ${operator_alias} (${operator_name})${NC}"
    echo "  Repo: ${repo_path}"

    # Validate repo exists
    if [[ ! -d "${repo_path}" ]]; then
        echo -e "${RED}✗ Repository not found: ${repo_path}${NC}"
        FAILED+=("${operator_alias}: repository not found")
        return 1
    fi

    pushd "${repo_path}" > /dev/null

    # Save original ref to restore later
    local original_ref
    original_ref=$(git symbolic-ref --quiet --short HEAD || git rev-parse HEAD)

    # Determine which branch to use: CLI override > config default > current branch
    branch="${branch_override:-$default_branch}"

    # Checkout branch if specified (either via override or default_branch)
    if [[ -n "$branch" ]]; then
        echo "  Switching to branch: ${branch}"
        if ! run_with_output 3 git checkout "${branch}"; then
            echo -e "${RED}✗ Failed to checkout branch: ${branch}${NC}"
            FAILED+=("${operator_alias}: checkout failed")
            popd > /dev/null
            return 1
        fi
    fi

    # Report current state
    local current_branch
    current_branch=$(git branch --show-current 2>/dev/null || echo "")
    if [[ -z "$current_branch" ]]; then
        echo "  Branch: (detached HEAD)"
    else
        echo "  Branch: ${current_branch}"
    fi

    echo "  Image: ${image_ref}"
    echo "  Building..."

    local failure=""
    if ! run_with_output 10 podman build --authfile="${auth_file}" --file "${dockerfile}" -t "${image_ref}" .; then
        failure="build failed"
    else
        echo "  Pushing..."
        if ! run_with_output 5 podman push --authfile="${auth_file}" "${image_ref}"; then
            failure="push failed"
        fi
    fi

    git checkout "${original_ref}" &>/dev/null || true
    popd > /dev/null

    if [[ -n "$failure" ]]; then
        echo -e "${RED}✗ ${operator_alias}: ${failure}${NC}"
        FAILED+=("${operator_alias}: ${failure}")
        return 1
    fi

    echo -e "${GREEN}✓ Built and pushed: ${image_ref}${NC}"
    SUCCEEDED+=("${operator_alias}: ${image_ref}")
    return 0
}

# Parse command line
NAMESPACE="${DEFAULT_NAMESPACE}"
TAG="${DEFAULT_TAG}"
VERBOSE=false
declare -a OPERATORS=()

while [[ $# -gt 0 ]]; do
    case "$1" in
        -n|--namespace)
            if [[ -z "${2:-}" ]] || [[ "$2" == -* ]]; then
                echo "Error: -n/--namespace requires a value"
                exit 1
            fi
            NAMESPACE="$2"
            shift 2
            ;;
        -t|--tag)
            if [[ -z "${2:-}" ]] || [[ "$2" == -* ]]; then
                echo "Error: -t/--tag requires a value"
                exit 1
            fi
            TAG="$2"
            shift 2
            ;;
        -v|--verbose)
            VERBOSE=true
            shift
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            OPERATORS+=("$1")
            shift
            ;;
    esac
done

if [[ ${#OPERATORS[@]} -eq 0 ]]; then
    echo "Error: No operators specified"
    echo ""
    usage
    exit 1
fi

# Load config files
if [[ ! -f "$CONFIG_FILE" ]]; then
    echo "Error: Config file not found: $CONFIG_FILE"
    exit 1
fi

parse_config "$CONFIG_FILE"

echo "========================================"
echo "Building ${#OPERATORS[@]} operator(s)"
echo "Registry: ${NAMESPACE}"
echo "Tag: ${TAG}"
echo "========================================"
echo ""

# Check registry access
if ! check_registry_access "$DEFAULT_AUTH_FILE"; then
    exit 1
fi
echo ""

# Process each operator
for op_spec in "${OPERATORS[@]}"; do
    # Split operator:branch format
    if [[ "$op_spec" == *:* ]]; then
        operator="${op_spec%%:*}"
        branch="${op_spec#*:}"
    else
        operator="$op_spec"
        branch=""
    fi

    build_operator "$operator" "$branch" "$NAMESPACE" "$TAG" "$DEFAULT_AUTH_FILE" || true
    echo ""
done

# Print summary
echo "========================================"
echo "BUILD SUMMARY"
echo "========================================"

if [[ ${#SUCCEEDED[@]} -gt 0 ]]; then
    echo -e "${GREEN}SUCCEEDED (${#SUCCEEDED[@]}):${NC}"
    for item in "${SUCCEEDED[@]}"; do
        echo -e "  ${GREEN}✓${NC} $item"
    done
    echo ""
fi

if [[ ${#FAILED[@]} -gt 0 ]]; then
    echo -e "${RED}FAILED (${#FAILED[@]}):${NC}"
    for item in "${FAILED[@]}"; do
        echo -e "  ${RED}✗${NC} $item"
    done
    echo ""
    exit 1
fi

echo -e "${GREEN}All operators built.${NC}"
