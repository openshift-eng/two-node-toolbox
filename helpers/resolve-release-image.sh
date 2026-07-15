#!/usr/bin/bash
set -euo pipefail

SCRIPT_NAME="$(basename "$0")"
readonly SCRIPT_NAME
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIR
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
readonly REPO_ROOT

readonly QUAY_REPO="openshift-release-dev/ocp-release"
readonly QUAY_TAG_API="https://quay.io/api/v1/repository/${QUAY_REPO}/tag/"
readonly RC_AMD64="https://amd64.ocp.releases.ci.openshift.org/api/v1/releasestream"
readonly RC_ARM64="https://arm64.ocp.releases.ci.openshift.org/api/v1/releasestream"
readonly CI_REGISTRY="registry.ci.openshift.org"

readonly COLOR_RED='\033[0;31m'
readonly COLOR_YELLOW='\033[0;33m'
readonly COLOR_GREEN='\033[0;32m'
readonly COLOR_BLUE='\033[0;34m'
readonly COLOR_CLEAR='\033[0m'

msg_err()  { echo -e "${COLOR_RED}ERROR: ${1}${COLOR_CLEAR}" >&2; }
msg_warn() { echo -e "${COLOR_YELLOW}WARN: ${1}${COLOR_CLEAR}" >&2; }
msg_ok()   { echo -e "${COLOR_GREEN}OK: ${1}${COLOR_CLEAR}" >&2; }
msg_info() { echo -e "${COLOR_BLUE}INFO: ${1}${COLOR_CLEAR}" >&2; }

QUIET="false"
info() { [[ "$QUIET" == "true" ]] || msg_info "$1"; }
ok()   { [[ "$QUIET" == "true" ]] || msg_ok "$1"; }

valreq() { [[ -n "${2-}" && "$2" != -* ]]; }

fetch_url() { curl -fsS --connect-timeout 30 "$@"; }

require_json_tool() {
    command -v jq >/dev/null 2>&1 || command -v python3 >/dev/null 2>&1 || {
        msg_err "jq or python3 required to parse JSON API responses"
        exit 2
    }
}

# ---------------------------------------------------------------------------
# Image reference helpers
# ---------------------------------------------------------------------------

IMG_REGISTRY="" IMG_REPO="" IMG_TAG="" IMG_DIGEST=""

parse_image_ref() {
    local ref="$1"
    IMG_REGISTRY="" IMG_REPO="" IMG_TAG="" IMG_DIGEST=""

    if [[ "$ref" == *"@"* ]]; then
        IMG_DIGEST="${ref#*@}"
        ref="${ref%%@*}"
    fi
    if [[ "$ref" == *":"* ]]; then
        local after="${ref##*:}"
        if [[ "$after" != *"/"* ]]; then
            IMG_TAG="$after"
            ref="${ref%:*}"
        fi
    fi
    local first="${ref%%/*}"
    if [[ "$first" == *"."* || "$first" == *":"* ]]; then
        IMG_REGISTRY="$first"
        IMG_REPO="${ref#*/}"
    else
        IMG_REGISTRY="docker.io"
        IMG_REPO="$ref"
    fi
}

image_repo_sans_tag() {
    local r="${1%%@*}"
    if [[ "$r" == *":"* ]]; then
        local after="${r##*:}"
        [[ "$after" != *"/"* ]] && r="${r%:*}"
    fi
    echo "$r"
}

# ---------------------------------------------------------------------------
# Registry auth
# ---------------------------------------------------------------------------

extract_registry_auth() {
    local registry="$1" pull_secret="$2"
    [[ -f "$pull_secret" ]] || return 1
    if command -v jq >/dev/null 2>&1; then
        jq -r ".auths[\"${registry}\"].auth // empty" "$pull_secret" 2>/dev/null
    elif command -v python3 >/dev/null 2>&1; then
        python3 -c "
import json, sys
with open(sys.argv[1]) as f:
    d = json.load(f)
a = d.get('auths',{}).get(sys.argv[2],{}).get('auth','')
if a: print(a, end='')
" "$pull_secret" "$registry" 2>/dev/null
    fi
}

get_bearer_token() {
    local registry="$1" repo="$2" pull_secret="${3:-}" ci_token="${4:-}"

    if [[ "$registry" == "$CI_REGISTRY" ]]; then
        if [[ -n "$ci_token" ]]; then
            echo "$ci_token"
            return 0
        fi
        local auth_b64
        auth_b64="$(extract_registry_auth "$registry" "$pull_secret")" || true
        if [[ -n "$auth_b64" ]]; then
            local decoded
            decoded=$(echo "$auth_b64" | base64 -d 2>/dev/null) || true
            [[ -n "$decoded" ]] && { echo "${decoded#*:}"; return 0; }
        fi
        return 1
    fi

    local headers realm service
    headers=$(curl -sI --connect-timeout 10 "https://${registry}/v2/" 2>/dev/null) || true
    realm=$(echo "$headers" | grep -ioP 'realm="\K[^"]+' | head -1) || true
    service=$(echo "$headers" | grep -ioP 'service="\K[^"]+' | head -1) || true
    [[ -n "$realm" ]] || return 1

    local auth_args=()
    local auth_b64
    auth_b64="$(extract_registry_auth "$registry" "$pull_secret")" || true
    [[ -n "$auth_b64" ]] && auth_args=(-H "Authorization: Basic ${auth_b64}")

    local token_json
    token_json=$(curl -fsS --connect-timeout 10 "${auth_args[@]}" \
        "${realm}?service=${service}&scope=repository:${repo}:pull" 2>/dev/null) || return 1

    if command -v jq >/dev/null 2>&1; then
        jq -r '.token // empty' <<< "$token_json"
    else
        python3 -c "import json,sys;t=json.load(sys.stdin).get('token','');print(t,end='') if t else None" <<< "$token_json"
    fi
}

registry_head_digest() {
    local registry="$1" repo="$2" reference="$3" bearer_token="${4:-}"

    local auth_args=()
    [[ -n "$bearer_token" ]] && auth_args=(-H "Authorization: Bearer ${bearer_token}")

    local tmpfile
    tmpfile=$(mktemp)
    local http_code
    http_code=$(curl -sI --connect-timeout 30 \
        -H "Accept: application/vnd.oci.image.index.v1+json, application/vnd.docker.distribution.manifest.list.v2+json, application/vnd.docker.distribution.manifest.v2+json" \
        "${auth_args[@]}" \
        -o /dev/null -D "$tmpfile" -w "%{http_code}" \
        "https://${registry}/v2/${repo}/manifests/${reference}" 2>/dev/null) || http_code="000"

    local digest=""
    [[ "$http_code" == "200" ]] && \
        digest=$(grep -i '^docker-content-digest:' "$tmpfile" | awk '{print $2}' | tr -d '\r\n')
    rm -f "$tmpfile"

    case "$http_code" in
        200) echo "$digest"; return 0 ;;
        401|403) return 1 ;;
        *) return 1 ;;
    esac
}

access_hint() {
    local registry="$1"
    if [[ "$registry" == "$CI_REGISTRY" ]]; then
        msg_err "  Refresh CI token: https://console-openshift-console.apps.ci.l2s4.p1.openshiftapps.com"
        msg_err "  Then run /setup or pass --ci-token"
    else
        msg_err "  Check pull-secret.json has auth for ${registry}"
        msg_err "  Update credentials via /setup"
    fi
}

# ---------------------------------------------------------------------------
# Version spec parsing
# ---------------------------------------------------------------------------

MAJOR_MINOR="" KIND="" EXPLICIT_VERSION=""

parse_version_spec() {
    local spec="$1"
    MAJOR_MINOR="" KIND="" EXPLICIT_VERSION=""

    if [[ "$spec" =~ ^([0-9]+\.[0-9]+)\.[0-9]+$ ]]; then
        MAJOR_MINOR="${BASH_REMATCH[1]}"
        EXPLICIT_VERSION="$spec"
        KIND="explicit"
        return 0
    fi
    if [[ "$spec" =~ ^([0-9]+\.[0-9]+)-(.+)$ ]]; then
        MAJOR_MINOR="${BASH_REMATCH[1]}"
        KIND="${BASH_REMATCH[2]}"
        case "$KIND" in
            nightly|ec|rc|prerelease|ga) return 0 ;;
            *) msg_err "Invalid kind '${KIND}' in '${spec}' (expected: nightly, ec, rc, prerelease, ga)"; return 1 ;;
        esac
    fi
    if [[ "$spec" =~ ^[0-9]+\.[0-9]+$ ]]; then
        MAJOR_MINOR="$spec"
        KIND="ga"
        return 0
    fi

    msg_err "Invalid version spec: '${spec}'"
    msg_err "  Expected: X.Y, X.Y-KIND (nightly|ec|rc|prerelease|ga), or X.Y.Z"
    return 1
}

# ---------------------------------------------------------------------------
# Resolution: nightly (release controller)
# ---------------------------------------------------------------------------

resolve_nightly() {
    local major_minor="$1" arch="$2"
    local stream rc_base

    if [[ "$arch" == "x86_64" ]]; then
        stream="${major_minor}.0-0.nightly"
        rc_base="$RC_AMD64"
    else
        stream="${major_minor}.0-0.nightly-arm64"
        rc_base="$RC_ARM64"
    fi

    info "Querying release controller: ${stream}"

    local json
    json="$(fetch_url "${rc_base}/${stream}/tags")" || {
        msg_err "Failed to reach release controller for ${stream}"
        return 1
    }

    local pullspec
    if command -v jq >/dev/null 2>&1; then
        pullspec=$(jq -r '(.tags // []) | map(select(.phase == "Accepted")) | .[0].pullSpec // empty' <<< "$json")
    else
        pullspec=$(python3 -c '
import json, sys
data = json.load(sys.stdin)
for t in data.get("tags") or []:
    if t.get("phase") == "Accepted" and t.get("pullSpec"):
        print(t["pullSpec"], end="")
        break
' <<< "$json")
    fi

    [[ -n "$pullspec" ]] || { msg_err "No Accepted nightly found for ${stream}"; return 1; }

    info "Found: ${pullspec}"
    echo "$pullspec"
}

# ---------------------------------------------------------------------------
# Resolution: stable (quay.io ga/ec/rc/prerelease)
# ---------------------------------------------------------------------------

fetch_quay_tags() {
    local filter="$1"
    local page=1 all_tags=""

    while true; do
        local response
        response="$(fetch_url "${QUAY_TAG_API}?page=${page}&limit=100&filter_tag_name=like:${filter}")" || {
            msg_err "Failed to fetch tags from quay.io (page ${page})"
            return 1
        }

        local page_tags has_more
        if command -v jq >/dev/null 2>&1; then
            page_tags=$(jq -r '(.tags // [])[] | .name' <<< "$response")
            has_more=$(jq -r '.has_additional // false' <<< "$response")
        else
            page_tags=$(python3 -c '
import json, sys
for t in json.load(sys.stdin).get("tags") or []:
    n = t.get("name","")
    if n: print(n)
' <<< "$response")
            has_more=$(python3 -c '
import json, sys
print("true" if json.load(sys.stdin).get("has_additional") else "false")
' <<< "$response")
        fi

        [[ -n "$page_tags" ]] && all_tags+="${page_tags}"$'\n'
        [[ "$has_more" == "true" ]] || break
        ((page++))
    done

    echo "$all_tags"
}

build_version_filter() {
    local mm_esc="$1" kind="$2" suffix="$3"
    case "$kind" in
        ga)         echo "^${mm_esc}\.[0-9]+-${suffix}$" ;;
        ec)         echo "^${mm_esc}\.[0-9]+-ec\.[0-9]+-${suffix}$" ;;
        rc)         echo "^${mm_esc}\.[0-9]+-rc\.[0-9]+-${suffix}$" ;;
        prerelease) echo "^${mm_esc}\.[0-9]+-(ec|rc)\.[0-9]+-${suffix}$" ;;
    esac
}

resolve_stable() {
    local major_minor="$1" kind="$2" arch="$3"
    local arch_suffix
    [[ "$arch" == "aarch64" ]] && arch_suffix="aarch64" || arch_suffix="multi"

    info "Querying quay.io for ${major_minor} ${kind} (${arch})"

    local all_tags
    all_tags="$(fetch_quay_tags "${major_minor}.")" || return 1
    [[ -n "$all_tags" ]] || { msg_err "No tags found for ${major_minor} on quay.io"; return 1; }

    local mm_esc="${major_minor//./\\.}"
    local filter_regex versions

    filter_regex="$(build_version_filter "$mm_esc" "$kind" "$arch_suffix")"
    versions=$(grep -E "$filter_regex" <<< "$all_tags" | sed "s/-${arch_suffix}$//" || true)

    if [[ -z "$versions" && "$arch" == "x86_64" && "$arch_suffix" == "multi" ]]; then
        msg_warn "No -multi tags for ${major_minor} ${kind}; trying -x86_64"
        arch_suffix="x86_64"
        filter_regex="$(build_version_filter "$mm_esc" "$kind" "$arch_suffix")"
        versions=$(grep -E "$filter_regex" <<< "$all_tags" | sed "s/-${arch_suffix}$//" || true)
    fi

    [[ -n "$versions" ]] || { msg_err "No ${kind} release found for ${major_minor} on quay.io"; return 1; }

    local latest
    latest=$(sort -V <<< "$versions" | tail -1)
    local tag="${latest}-${arch_suffix}"

    info "Resolved: ${latest} -> quay.io/${QUAY_REPO}:${tag}"
    echo "quay.io/${QUAY_REPO}:${tag}"
}

# ---------------------------------------------------------------------------
# Resolution: explicit version (X.Y.Z)
# ---------------------------------------------------------------------------

check_quay_tag() {
    local tag="$1"
    local response
    response="$(fetch_url "${QUAY_TAG_API}?specificTag=${tag}")" || return 1
    if command -v jq >/dev/null 2>&1; then
        jq -r '(.tags // []) | length' <<< "$response"
    else
        python3 -c 'import json,sys;print(len(json.load(sys.stdin).get("tags") or []))' <<< "$response"
    fi
}

resolve_explicit() {
    local version="$1" arch="$2"
    local arch_suffix
    [[ "$arch" == "aarch64" ]] && arch_suffix="aarch64" || arch_suffix="multi"

    local tag="${version}-${arch_suffix}"
    info "Checking quay.io for ${tag}"

    local found
    found="$(check_quay_tag "$tag")" || { msg_err "Failed to query quay.io"; return 1; }

    if [[ "$found" -gt 0 ]]; then
        echo "quay.io/${QUAY_REPO}:${tag}"
        return 0
    fi

    if [[ "$arch" == "x86_64" && "$arch_suffix" == "multi" ]]; then
        msg_warn "Tag ${tag} not found; trying -x86_64"
        tag="${version}-x86_64"
        found="$(check_quay_tag "$tag")" || return 1
        if [[ "$found" -gt 0 ]]; then
            echo "quay.io/${QUAY_REPO}:${tag}"
            return 0
        fi
    fi

    msg_err "Version ${version} not found on quay.io"
    return 1
}

# ---------------------------------------------------------------------------
# Digest resolution
# ---------------------------------------------------------------------------

resolve_digest() {
    local pullspec="$1" pull_secret="$2" ci_token="$3"

    [[ "$pullspec" != *"@sha256:"* ]] || { echo "$pullspec"; return 0; }

    if command -v oc >/dev/null 2>&1 && [[ -f "$pull_secret" ]]; then
        info "Resolving digest via oc adm release info"
        local digest
        if digest="$(oc adm release info --registry-config "$pull_secret" "$pullspec" \
                -o 'jsonpath={.digest}' 2>/dev/null)" && [[ -n "$digest" ]]; then
            echo "$(image_repo_sans_tag "$pullspec")@${digest}"
            return 0
        fi
        msg_warn "oc adm release info failed; trying registry API"
    fi

    parse_image_ref "$pullspec"
    local reference="${IMG_TAG:-${IMG_DIGEST}}"
    [[ -n "$reference" ]] || { msg_err "Cannot determine tag/digest from: ${pullspec}"; return 4; }

    info "Resolving digest via registry API"
    local token
    token="$(get_bearer_token "$IMG_REGISTRY" "$IMG_REPO" "$pull_secret" "$ci_token" 2>/dev/null)" || true

    local digest
    if ! digest="$(registry_head_digest "$IMG_REGISTRY" "$IMG_REPO" "$reference" "$token")"; then
        msg_err "Access denied resolving digest for ${pullspec}"
        access_hint "$IMG_REGISTRY"
        return 5
    fi

    [[ -n "$digest" ]] || { msg_err "Could not resolve digest for ${pullspec}"; return 4; }
    echo "$(image_repo_sans_tag "$pullspec")@${digest}"
}

# ---------------------------------------------------------------------------
# Access validation
# ---------------------------------------------------------------------------

validate_access() {
    local pullspec="$1" pull_secret="$2" ci_token="$3"

    if command -v oc >/dev/null 2>&1 && [[ -f "$pull_secret" ]]; then
        info "Validating access via oc adm release info"
        if oc adm release info --registry-config "$pull_secret" "$pullspec" >/dev/null 2>&1; then
            return 0
        fi
        msg_warn "oc validation failed; trying registry API"
    fi

    parse_image_ref "$pullspec"
    local reference="${IMG_TAG:-${IMG_DIGEST}}"
    [[ -n "$reference" ]] || { msg_err "Cannot determine tag/digest from: ${pullspec}"; return 1; }

    local token
    token="$(get_bearer_token "$IMG_REGISTRY" "$IMG_REPO" "$pull_secret" "$ci_token" 2>/dev/null)" || true

    if ! registry_head_digest "$IMG_REGISTRY" "$IMG_REPO" "$reference" "$token" >/dev/null; then
        msg_err "Access denied: ${pullspec}"
        access_hint "$IMG_REGISTRY"
        return 1
    fi
}

# ---------------------------------------------------------------------------
# Usage
# ---------------------------------------------------------------------------

usage() {
    cat >&2 <<EOF
Resolve an OCP version spec to a concrete release image pullspec.

Usage:
    ${SCRIPT_NAME} (--version SPEC | --pullspec IMAGE) [OPTIONS]

Version spec:
    --version SPEC          X.Y, X.Y-KIND, or X.Y.Z
                            KIND: nightly, ec, rc, prerelease, ga (default: ga)
                            Examples: 4.21-nightly, 4.20, 4.20-ec, 4.19.12
    --pullspec IMAGE        Explicit image (digest/validation still apply)

Options:
    --arch ARCH             x86_64 or aarch64 (default: x86_64)
    --digest                Output repo@sha256:... instead of tagged ref
    --pull-secret PATH      Pull secret JSON (default: config/pull-secret.json)
    --validate-access       Verify the resolved image is pullable
    --ci-token TOKEN        Bearer token for ${CI_REGISTRY}
    --quiet                 Suppress informational messages
    -h, --help              Show this help

Exit codes:
    0   Success (pullspec on stdout)
    2   Usage error / invalid spec
    3   Resolution failed (API unreachable, no matching release)
    4   Digest resolution failed
    5   Access denied (invalid credentials)

Resolution sources:
    nightly     Release controller (registry.ci.openshift.org)
    ga/ec/rc    Quay.io tag API (quay.io/openshift-release-dev/ocp-release)

Examples:
    # Latest 4.21 GA for x86_64
    ${SCRIPT_NAME} --version 4.21

    # Latest 4.22 nightly on aarch64
    ${SCRIPT_NAME} --version 4.22-nightly --arch aarch64

    # Specific version, pinned by digest (for agent installs)
    ${SCRIPT_NAME} --version 4.21 --digest --pull-secret config/pull-secret.json

    # Latest EC/RC prerelease
    ${SCRIPT_NAME} --version 4.22-prerelease

    # Validate access to a CI nightly
    ${SCRIPT_NAME} --version 4.21-nightly --validate-access --ci-token \$CI_TOKEN
EOF
    exit "${1:-0}"
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

VERSION_SPEC=""
PULLSPEC=""
ARCH="x86_64"
WANT_DIGEST="false"
PULL_SECRET=""
VALIDATE_ACCESS="false"
CI_TOKEN_VALUE=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --version)
            valreq "$1" "${2-}" || { msg_err "--version requires a value"; exit 2; }
            VERSION_SPEC="$2"; shift 2 ;;
        --pullspec)
            valreq "$1" "${2-}" || { msg_err "--pullspec requires a value"; exit 2; }
            PULLSPEC="$2"; shift 2 ;;
        --arch)
            valreq "$1" "${2-}" || { msg_err "--arch requires a value"; exit 2; }
            ARCH="$2"; shift 2 ;;
        --digest)
            WANT_DIGEST="true"; shift ;;
        --pull-secret)
            valreq "$1" "${2-}" || { msg_err "--pull-secret requires a value"; exit 2; }
            PULL_SECRET="$2"; shift 2 ;;
        --validate-access)
            VALIDATE_ACCESS="true"; shift ;;
        --ci-token)
            valreq "$1" "${2-}" || { msg_err "--ci-token requires a value"; exit 2; }
            CI_TOKEN_VALUE="$2"; shift 2 ;;
        --quiet|-q)
            QUIET="true"; shift ;;
        -h|--help)
            usage 0 ;;
        *)
            msg_err "Unknown option: $1"; usage 2 ;;
    esac
done

if [[ -z "$VERSION_SPEC" && -z "$PULLSPEC" ]]; then
    msg_err "One of --version or --pullspec is required"
    usage 2
fi
if [[ -n "$VERSION_SPEC" && -n "$PULLSPEC" ]]; then
    msg_err "Use only one of --version or --pullspec"
    exit 2
fi
case "$ARCH" in
    x86_64|aarch64) ;;
    *) msg_err "Invalid --arch: ${ARCH} (expected: x86_64, aarch64)"; exit 2 ;;
esac

[[ -n "$PULL_SECRET" ]] || PULL_SECRET="${REPO_ROOT}/config/pull-secret.json"
require_json_tool

RESOLVED=""

if [[ -n "$PULLSPEC" ]]; then
    info "Using explicit pullspec: ${PULLSPEC}"
    RESOLVED="$PULLSPEC"
else
    parse_version_spec "$VERSION_SPEC" || exit 2
    case "$KIND" in
        nightly)
            RESOLVED="$(resolve_nightly "$MAJOR_MINOR" "$ARCH")" || exit 3 ;;
        ga|ec|rc|prerelease)
            RESOLVED="$(resolve_stable "$MAJOR_MINOR" "$KIND" "$ARCH")" || exit 3 ;;
        explicit)
            RESOLVED="$(resolve_explicit "$EXPLICIT_VERSION" "$ARCH")" || exit 3 ;;
    esac
fi

if [[ "$VALIDATE_ACCESS" == "true" ]]; then
    validate_access "$RESOLVED" "$PULL_SECRET" "$CI_TOKEN_VALUE" || exit 5
    ok "Access validated for ${RESOLVED}"
fi

if [[ "$WANT_DIGEST" == "true" ]]; then
    RESOLVED="$(resolve_digest "$RESOLVED" "$PULL_SECRET" "$CI_TOKEN_VALUE")" || exit $?
    ok "Digest resolved"
fi

echo "$RESOLVED"
