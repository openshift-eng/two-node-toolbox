#!/usr/bin/env bash
set -euo pipefail

SCRIPT_NAME="$(basename "$0")"
readonly SCRIPT_NAME
readonly DEFAULT_REGISTRY="quay.io"
readonly DEFAULT_NAMESPACE="rh-edge-enablement"
readonly DEFAULT_REF="main"
readonly DEFAULT_TAG="latest"
readonly IRONIC_IMAGE_REPO="https://github.com/metal3-io/ironic-image.git"
readonly ALL_IMAGES="ironic,vbmc,sushy-tools"

readonly COLOR_RED='\033[0;31m'
readonly COLOR_YELLOW='\033[0;33m'
readonly COLOR_GREEN='\033[0;32m'
readonly COLOR_BLUE='\033[0;34m'
readonly COLOR_CLEAR='\033[0m'

msg_err()  { echo -e "${COLOR_RED}ERROR: ${1}${COLOR_CLEAR}" >&2; }
msg_warn() { echo -e "${COLOR_YELLOW}WARN: ${1}${COLOR_CLEAR}" >&2; }
msg_ok()   { echo -e "${COLOR_GREEN}OK: ${1}${COLOR_CLEAR}"; }
msg_info() { echo -e "${COLOR_BLUE}INFO: ${1}${COLOR_CLEAR}"; }

valreq() { [[ -n "${2-}" && "$2" != -* ]]; }

usage() {
    cat <<EOF
Build arm64 Metal3 container images (ironic, vbmc, sushy-tools).

Upstream metal3-io only publishes amd64 images. This script builds arm64
variants from the same source and pushes them to a registry you control.

Usage:
    ${SCRIPT_NAME} [OPTIONS]

Options:
    --namespace <ns>    Registry namespace (default: ${DEFAULT_NAMESPACE})
    --registry <reg>    Container registry (default: ${DEFAULT_REGISTRY})
    --ref <git-ref>     ironic-image git ref to build from (default: ${DEFAULT_REF})
    --tag <tag>         Image tag to apply (default: ${DEFAULT_TAG})
    --images <list>     Comma-separated images to build (default: ${ALL_IMAGES})
    --no-push           Build only, do not push to registry
    --keep-source       Do not remove cloned source after build
    --source-dir <dir>  Use existing ironic-image checkout instead of cloning
    -h, --help          Show this help

Examples:
    # Build all images and push to quay.io/rh-edge-enablement
    ${SCRIPT_NAME}

    # Build from a release tag, push with date-based tag
    ${SCRIPT_NAME} --ref v28.0.0 --tag 2026-06

    # Build only sushy-tools, don't push
    ${SCRIPT_NAME} --images sushy-tools --no-push

    # Use a different registry namespace
    ${SCRIPT_NAME} --namespace pfontani

Prerequisites:
    - podman (with qemu-user-static if cross-building from x86_64)
    - Authenticated to the target registry (podman login ${DEFAULT_REGISTRY})
    - Git
EOF
    exit "${1:-0}"
}

REGISTRY="${DEFAULT_REGISTRY}"
NAMESPACE="${DEFAULT_NAMESPACE}"
REF="${DEFAULT_REF}"
TAG="${DEFAULT_TAG}"
IMAGES="${ALL_IMAGES}"
PUSH="true"
KEEP_SOURCE="false"
SOURCE_DIR=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --namespace)
            valreq "$1" "${2-}" || { msg_err "--namespace requires a value"; exit 1; }
            NAMESPACE="$2"; shift 2 ;;
        --registry)
            valreq "$1" "${2-}" || { msg_err "--registry requires a value"; exit 1; }
            REGISTRY="$2"; shift 2 ;;
        --ref)
            valreq "$1" "${2-}" || { msg_err "--ref requires a value"; exit 1; }
            REF="$2"; shift 2 ;;
        --tag)
            valreq "$1" "${2-}" || { msg_err "--tag requires a value"; exit 1; }
            TAG="$2"; shift 2 ;;
        --images)
            valreq "$1" "${2-}" || { msg_err "--images requires a value"; exit 1; }
            IMAGES="$2"; shift 2 ;;
        --no-push)
            PUSH="false"; shift ;;
        --keep-source)
            KEEP_SOURCE="true"; shift ;;
        --source-dir)
            valreq "$1" "${2-}" || { msg_err "--source-dir requires a value"; exit 1; }
            SOURCE_DIR="$2"; shift 2 ;;
        -h|--help)
            usage 0 ;;
        *)
            msg_err "Unknown option: $1"; usage 1 ;;
    esac
done

check_prerequisites() {
    if ! command -v podman &>/dev/null; then
        msg_err "podman is required but not found"
        exit 1
    fi
    if ! command -v git &>/dev/null; then
        msg_err "git is required but not found"
        exit 1
    fi

    local host_arch
    host_arch="$(uname -m)"

    if [[ "${host_arch}" != "aarch64" ]]; then
        msg_info "Host is ${host_arch} — cross-building for arm64 via QEMU"
        if ! ls /proc/sys/fs/binfmt_misc/qemu-aarch64 &>/dev/null; then
            msg_warn "QEMU binfmt handler for aarch64 not found"
            msg_info "Install with: sudo dnf install -y qemu-user-static"
            msg_info "Then restart binfmt: sudo systemctl restart systemd-binfmt"
            exit 1
        fi
    else
        msg_info "Host is aarch64 — building natively"
    fi

    if [[ "${PUSH}" == "true" ]]; then
        if ! podman login --get-login "${REGISTRY}" &>/dev/null; then
            msg_err "Not authenticated to ${REGISTRY}. Run: podman login ${REGISTRY}"
            exit 1
        fi
    fi
}

prepare_source() {
    if [[ -n "${SOURCE_DIR}" ]]; then
        if [[ ! -d "${SOURCE_DIR}" ]]; then
            msg_err "Source directory does not exist: ${SOURCE_DIR}"
            exit 1
        fi
        WORK_DIR="${SOURCE_DIR}"
        KEEP_SOURCE="true"
        if ! git -C "${WORK_DIR}" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
            msg_err "--source-dir is not a git checkout: ${WORK_DIR}"
            exit 1
        fi
        if ! git -C "${WORK_DIR}" rev-parse --verify "${REF}^{commit}" >/dev/null 2>&1; then
            msg_err "Ref '${REF}' not found in --source-dir. Fetch it or pass a valid --ref."
            exit 1
        fi
        local head_commit ref_commit
        head_commit="$(git -C "${WORK_DIR}" rev-parse HEAD)"
        ref_commit="$(git -C "${WORK_DIR}" rev-parse "${REF}^{commit}")"
        if [[ "${head_commit}" != "${ref_commit}" ]]; then
            msg_err "--source-dir HEAD does not match --ref '${REF}'. Checkout the ref first."
            exit 1
        fi
        msg_info "Using existing source: ${WORK_DIR}"
    else
        WORK_DIR="$(mktemp -d)"
        msg_info "Cloning ironic-image at ref '${REF}' into ${WORK_DIR}"
        git clone --depth 1 --branch "${REF}" "${IRONIC_IMAGE_REPO}" "${WORK_DIR}" 2>&1 \
            || git clone "${IRONIC_IMAGE_REPO}" "${WORK_DIR}" 2>&1
        if ! git -C "${WORK_DIR}" rev-parse --verify "${REF}^{commit}" >/dev/null 2>&1; then
            git -C "${WORK_DIR}" fetch origin "${REF}" 2>&1
        fi
        git -C "${WORK_DIR}" checkout "${REF}" 2>&1
    fi

    local commit
    commit="$(git -C "${WORK_DIR}" rev-parse --short HEAD 2>/dev/null || echo 'unknown')"
    msg_info "Source commit: ${commit}"
}

cleanup_source() {
    if [[ "${KEEP_SOURCE}" == "false" && -n "${WORK_DIR:-}" && -d "${WORK_DIR}" ]]; then
        rm -rf "${WORK_DIR}"
        msg_info "Cleaned up source directory"
    fi
}

build_image() {
    local image_name="$1"
    local full_tag="${REGISTRY}/${NAMESPACE}/${image_name}:${TAG}"
    local dockerfile_dir="."
    local build_args=()

    case "${image_name}" in
        ironic)
            dockerfile_dir="."
            ;;
        vbmc)
            dockerfile_dir="resources/vbmc"
            ;;
        sushy-tools)
            dockerfile_dir="resources/sushy-tools"
            ;;
        *)
            msg_err "Unknown image: ${image_name}"
            return 1
            ;;
    esac

    msg_info "Building ${full_tag} from ${dockerfile_dir}/Dockerfile"

    local platform_flag=()
    if [[ "$(uname -m)" != "aarch64" ]]; then
        platform_flag=(--platform linux/arm64)
    fi

    if ! podman build \
        "${platform_flag[@]}" \
        -t "${full_tag}" \
        -f "${WORK_DIR}/${dockerfile_dir}/Dockerfile" \
        "${build_args[@]}" \
        "${WORK_DIR}/${dockerfile_dir}" 2>&1; then
        msg_err "Failed to build ${full_tag}"
        return 1
    fi

    msg_ok "Built ${full_tag}"
}

push_image() {
    local image_name="$1"
    local full_tag="${REGISTRY}/${NAMESPACE}/${image_name}:${TAG}"

    msg_info "Pushing ${full_tag}"
    if ! podman push "${full_tag}" 2>&1; then
        msg_err "Failed to push ${full_tag}"
        return 1
    fi
    msg_ok "Pushed ${full_tag}"
}

main() {
    msg_info "Metal3 arm64 image builder"
    msg_info "Registry: ${REGISTRY}/${NAMESPACE}"
    msg_info "Git ref: ${REF} | Tag: ${TAG}"
    msg_info "Images: ${IMAGES}"
    msg_info "Push: ${PUSH}"
    echo ""

    trap cleanup_source EXIT
    check_prerequisites
    prepare_source

    IFS=',' read -ra IMAGE_LIST <<< "${IMAGES}"

    local failed=()
    for image in "${IMAGE_LIST[@]}"; do
        image="$(echo "${image}" | xargs)"
        if build_image "${image}"; then
            if [[ "${PUSH}" == "true" ]]; then
                push_image "${image}" || failed+=("${image}")
            fi
        else
            failed+=("${image}")
        fi
    done

    echo ""
    if [[ ${#failed[@]} -gt 0 ]]; then
        msg_err "Failed images: ${failed[*]}"
        exit 1
    fi

    msg_ok "All images built successfully"
    echo ""
    msg_info "To use these images with dev-scripts, add to your config:"
    for image in "${IMAGE_LIST[@]}"; do
        image="$(echo "${image}" | xargs)"
        local var_name
        case "${image}" in
            ironic)      var_name="IRONIC_IMAGE" ;;
            vbmc)        var_name="VBMC_IMAGE" ;;
            sushy-tools) var_name="SUSHY_TOOLS_IMAGE" ;;
        esac
        echo "  export ${var_name}=${REGISTRY}/${NAMESPACE}/${image}:${TAG}"
    done
}

main
