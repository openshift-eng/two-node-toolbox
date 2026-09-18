#!/usr/bin/env bash
# Helper: resolve an OCP 5.x payload, print the rhel-coreos base image for a
# custom-OS layer Dockerfile, and run oc adm release new to publish the custom payload
# (when a custom OS ref is available and oc is not skipped).
#
# Flow: ./local-build-test.sh (Stream 9/10) builds resource-agents RPM; the combined
# Dockerfile (Dockerfile.custompayload) is built and pushed to DEFAULT_TO_IMAGE
# (custom OS layer). oc adm release new then publishes a custom *payload* to
# DEFAULT_TO_PAYLOAD_IMAGE (base repo; tag = nightly-whoami), mapping BASE_OS= to the pushed OS image @digest.
#
# Either pass --release PULLSPEC, or --auto-release to use the first tag in the
# 5.0.0-0.nightly stream with phase Accepted (newest-first order from the API).
#
# Default pull auth: PULL_SECRET_PATH, or -a, else ~/.docker/config.json (macOS)
# or ~/.config/containers/auth.json (Linux) as documented in --help.
#
# Quay label quay.expires-after defaults to 24h on both the RHCOS image (podman --label)
# and the payload (extra layer after oc adm release new); override with QUAY_EXPIRES_AFTER
# or --quay-expires-after, or use none to disable.
#
# Requires: curl; oc; podman; jq or python3 (for --auto-release). Use --print-only
# to skip oc, --no-build to skip podman after writing Dockerfile.
set -euo pipefail

API_5_NIGHTLY_URL="https://amd64.ocp.releases.ci.openshift.org/api/v1/releasestream/5.0.0-0.nightly/tags"
# Registry/repo (optional :tag) for the custom RHCOS *layer* after podman build/push.
DEFAULT_TO_IMAGE="quay.io/rh-edge-enablement/tnf-custom-rhcos"
# Base for the custom *release payload* --to-image; tag is set to <nightly>-<whoami> from the chosen release.
DEFAULT_TO_PAYLOAD_IMAGE="quay.io/rh-edge-enablement/tnf-custom-payload:latest"
SCRIPT_NAME="$(basename "$0")"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUT_DOCKERFILE="${OUT_DOCKERFILE:-${SCRIPT_DIR}/Dockerfile.custompayload}"

# --- defaults (override with env PAYLOAD_TO_IMAGE / CUSTOM_OS_TO_IMAGE or flags) ---
RELEASE_REF=""
PULL_SECRET_PATH="${PULL_SECRET_PATH:-}"
AUTHFILE="${PULL_SECRET_PATH:-}"
USE_AUTO_RELEASE="0"
BASE_OS="rhel-coreos-10"
CUSTOM_OS_TO_IMAGE="${CUSTOM_OS_TO_IMAGE:-${DEFAULT_TO_IMAGE}}"
PAYLOAD_TO_IMAGE="${PAYLOAD_TO_IMAGE:-${DEFAULT_TO_PAYLOAD_IMAGE}}"
CUSTOM_OS_IMAGE_REF="" # full ref for ${BASE_OS}= in oc command; if empty, filled from podman push digest when we build
SKIP_OC="0"
SKIP_PODMAN_BUILD="0" # set 1 with --no-build
BUILT_OCI_REF=""      # set after successful podman push: repo@sha256:... for oc adm
RPM_FILENAME="resource-agents.rpm" # for Dockerfile example only
RA_REPO="" # override resource-agents git repo (--repo)
RA_REF=""  # override resource-agents git ref  (--ref)
TARGET_COMPONENT="" # override release component to replace (default: same as BASE_OS; use rhel-coreos-extensions for extension RPMs)
# Quay garbage-collection hint (both OS layer and release payload). Set empty, none/off, or 0 to skip.
EXPIRES_LABEL_VALUE=""
QUAY_EXPIRES_AFTER_OVERRIDE="" # set with --quay-expires-after (bypasses env default for EXPIRES_LABEL_VALUE)

usage() {
    cat <<EOF
Usage: ${SCRIPT_NAME} [OPTIONS]

  Resolve a release payload, print the base OS image (oc adm release info),
  a minimal Dockerfile for rpm-ostree override, and run oc adm release new
  (unless --print-only / no OS ref) to publish the custom payload.

Release source (one required):
  --release PULLSPEC     Full payload image, e.g.
                         registry.ci.openshift.org/ocp/release-5:5.0.0-0.nightly-...
  --auto-release         Newest 5.0.0-0.nightly with phase Accepted from:
                         ${API_5_NIGHTLY_URL}

  -a, --authfile PATH    Path to OpenShift pull secret (JSON). If omitted,
                         uses a default for your OS (see below), or
                         PULL_SECRET_PATH in the environment.

  --base-os NAME        Image to resolve: rhel-coreos or rhel-coreos-10
                        (default: rhel-coreos-10, typical for RHEL 10 / OCP 5)

  --to-os-image REF     Where to tag/push the custom *OS layer* (podman build -t
                        and podman push). Default: ${DEFAULT_TO_IMAGE}
                        (or env CUSTOM_OS_TO_IMAGE)

  --to-payload-image REF
                        --to-image for oc adm release new (the custom *release
                        payload* image you push with oc). Default:
                        ${DEFAULT_TO_PAYLOAD_IMAGE} (tag is replaced with
                        <nightly_release_tag>-<whoami> from the payload you select).
                        Also settable via env PAYLOAD_TO_IMAGE.

  --to-image REF        Same as --to-payload-image (alias; payload only).

  --custom-os REF       Full ref for ${BASE_OS}= in oc adm (image@sha256:...). If
                        unset, a placeholder from --to-os-image is printed.

  --target-component NAME
                        Release component to replace. Default: same as --base-os.
                        Use rhel-coreos-extensions or rhel-coreos-10-extensions to
                        replace the RPM inside the extensions container (for packages
                        like resource-agents that are MCO extensions, not base OS).
                        Valid: rhel-coreos, rhel-coreos-10, rhel-coreos-extensions,
                        rhel-coreos-10-extensions

  --repo URL            resource-agents git repo for the RPM build
                        (default: upstream ClusterLabs/resource-agents)
  --ref REF             resource-agents git branch/tag/commit
                        (default: main)

  --rpm-filename NAME   Name used in the Dockerfile COPY / RUN example
                        (default: ${RPM_FILENAME})

  --quay-expires-after DURATION|none
                        Set Quay OCI label quay.expires-after on the built
                        RHCOS image and on the custom payload image. Default: 24h
                        (or env QUAY_EXPIRES_AFTER; use none/off to disable the label)

  --print-only          Do not run oc; only fetch release (with --auto-release)
                        and show placeholders for OS image and commands. Implies
                        no podman build (invalid RHCOS FROM in Dockerfile).

  --skip-oc             Same as not having oc, but do not error (skip
                        release info; use with --print-only for docs).

  --no-build            Write Dockerfile only; do not run podman build/push.

  -h, --help            This help

  Output also writes a combined file (see below).

Default pull secret when -a is omitted:
  - macOS (Darwin):  ~/.docker/config.json, then ~/.config/containers/auth.json
  - Linux:           ~/.config/containers/auth.json, then ~/.docker/config.json
  - Set PULL_SECRET_PATH or use -a to point at a pull-secret file from
    cloud.openshift.com or your registry auth JSON.

Quay label quay.expires-after (default 24h, override with --quay-expires-after
or env QUAY_EXPIRES_AFTER, use none to disable) is applied to the custom
RHCOS image (podman build --label) and to the payload after oc adm release new
(via a thin follow-up image build).

By default this script runs podman build against the generated Dockerfile and
pushes the image to --to-os-image (DEFAULT_TO_IMAGE) tagged as
<release_nightly_tag>-custom-<whoami> (e.g. 5.0.0-0.nightly-2026-04-22-094829-custom-alice), then
runs oc adm release new with the pushed image@sha256 when available (or with
--custom-os), unless --print-only, --skip-oc, or there is no OS image ref yet.

  oc adm release new -a <auth> \\
    --from-release <payload> \\
    --to-image <PAYLOAD_TO_IMAGE, same as --to-payload-image> \\
    <target-component>=<BUILT_OCI_REF from push, or your --custom-os>

  PAYLOAD_TO_IMAGE is set to <repo>:<nightly_from_payload>-<whoami> (no :latest-whoami).

(Component name defaults to --base-os; override with --target-component for extensions.)

Combined Dockerfile:
  The script appends the RHCOS override snippet to Dockerfile.stream9
  (when --base-os rhel-coreos) or Dockerfile.stream10 (when rhel-coreos-10) and
  writes the result to Dockerfile.custompayload in the script directory, or
  the path in OUT_DOCKERFILE if set.

EOF
    exit "${1:-0}"
}

err() { echo "Error: $*" >&2; exit 1; }

# Resolve quay.expires-after value: default 24h, env QUAY_EXPIRES_AFTER, --quay-expires-after wins;
# none|off|false|0 disables (empty means no --label / no relayer).
resolve_quay_expires_label() {
    local v raw
    raw="${QUAY_EXPIRES_AFTER_OVERRIDE:-}"
    if [[ -n "$raw" ]]; then
        v="$raw"
    else
        v="${QUAY_EXPIRES_AFTER:-24h}"
    fi
    case "${v,,}" in
        "" | none | off | "false" | 0) echo "" ;;
        *) echo "$v" ;;
    esac
}

# After oc adm release new, add Quay's garbage-collection label to the payload image.
relabel_pushed_payload_with_quay_expires() {
    local image_ref=$1
    local authfile=$2
    local expires_val=$3
    local tmpdir df

    [[ -n "$expires_val" ]] || return 0
    if ! command -v podman >/dev/null 2>&1; then
        err "podman not in PATH; cannot add label to payload image"
    fi

    tmpdir=$(mktemp -d) || err "mktemp -d failed"
    df="${tmpdir}/Containerfile"
    {
        printf 'FROM %s\n' "$image_ref"
        printf 'LABEL quay.expires-after=%s\n' "$expires_val"
    } > "$df"

    echo "Layering quay.expires-after=${expires_val} onto payload image: ${image_ref}"
    echo "  podman pull --authfile ${authfile} ${image_ref}"
    podman pull --authfile "$authfile" "$image_ref" || {
        rm -rf "$tmpdir"
        err "podman pull failed for ${image_ref}"
    }
    echo "  podman build --authfile ${authfile} -f ${df} -t ${image_ref} ${tmpdir}"
    podman build --authfile "$authfile" -f "$df" -t "$image_ref" "$tmpdir" || {
        rm -rf "$tmpdir"
        err "podman build (payload relabel) failed"
    }
    echo "  podman push --authfile ${authfile} ${image_ref}"
    podman push --authfile "$authfile" "$image_ref" || {
        rm -rf "$tmpdir"
        err "podman push (payload relabel) failed"
    }
    rm -rf "$tmpdir"
}

# macOS: Docker Desktop often uses ~/.docker/config.json; Linux: podman in ~/.config/containers
default_authfile() {
    local a
    for a in "$@"; do
        if [[ -f "$a" ]]; then
            echo "$a"
            return 0
        fi
    done
    return 1
}

resolve_default_authfile() {
    if [[ -n "${AUTHFILE}" ]]; then
        [[ -f "${AUTHFILE}" ]] || err "Pull secret not found: ${AUTHFILE}"
        echo "${AUTHFILE}"
        return
    fi
    case "$(uname -s 2>/dev/null || echo Linux)" in
        Darwin)
            if default_authfile \
                "${HOME}/.docker/config.json" \
                "${HOME}/.config/containers/auth.json"; then
                return
            fi
            ;;
        *)
            if default_authfile \
                "${HOME}/.config/containers/auth.json" \
                "${HOME}/.docker/config.json"; then
                return
            fi
            ;;
    esac
    err "No default pull secret found. Pass -a PATH or set PULL_SECRET_PATH to your pull secret JSON (e.g. from console.redhat.com)."
}

# Newest *Accepted* 5.0 nightly: API returns tags newest-first; pick first with phase == Accepted
fetch_auto_release_pullspec() {
    local json pullspec
    if ! json="$(curl -fsS --connect-timeout 30 "${API_5_NIGHTLY_URL}")"; then
        err "Failed to download ${API_5_NIGHTLY_URL}"
    fi
    if command -v jq >/dev/null 2>&1; then
        pullspec=$(echo "$json" | jq -r '(.tags // []) | map(select(.phase == "Accepted")) | .[0].pullSpec // empty')
    elif command -v python3 >/dev/null 2>&1; then
        pullspec=$(echo "$json" | python3 -c '
import json, sys
data = json.load(sys.stdin)
for t in data.get("tags") or []:
    if t.get("phase") == "Accepted" and t.get("pullSpec"):
        print(t["pullSpec"], end="")
        break
')
    else
        err "Need jq or python3 to parse the release API JSON"
    fi
    [[ -n "${pullspec}" ]] || err "No tag with phase Accepted in 5.0.0-0.nightly (see ${API_5_NIGHTLY_URL})"
    echo "${pullspec}"
}

validate_base_os() {
    case "$1" in
        rhel-coreos | rhel-coreos-10) return 0 ;;
        *) err "Invalid --base-os: $1 (use rhel-coreos or rhel-coreos-10)" ;;
    esac
}

validate_target_component() {
    case "$1" in
        rhel-coreos | rhel-coreos-10 | rhel-coreos-extensions | rhel-coreos-10-extensions) return 0 ;;
        *) err "Invalid --target-component: $1 (use rhel-coreos, rhel-coreos-10, rhel-coreos-extensions, or rhel-coreos-10-extensions)" ;;
    esac
}

effective_target_component() {
    echo "${TARGET_COMPONENT:-$BASE_OS}"
}

is_extensions_target() {
    [[ "$(effective_target_component)" == *-extensions ]]
}

# e.g. registry.ci.../ocp/release-5:5.0.0-0.nightly-2026-04-22-094829
nightly_tag_from_release_ref() {
    echo "${1##*:}"
}

# Strip digest (@sha256) and OCI :tag (last :… when not a port) to get a bare repo to retag.
image_repo_sans_tag_or_digest() {
    local r
    r="${1%%@*}"
    if [[ "$r" == *:* ]]; then
        local after="${r##*:}"
        if [[ "$after" != *"/"* ]]; then
            r="${r%:*}"
        fi
    fi
    echo "$r"
}

# Tag suffix: <nightly>-custom-<whoami> (e.g. ...094829-custom-alice)
oci_tag_nightly_custom() {
    local nightly
    nightly="$(nightly_tag_from_release_ref "$1")"
    echo "${nightly}-custom-$(whoami)"
}

# --to-image for oc adm: <repo from ref>:<nightly_tag_from_release>-<whoami> (aligns with nightly in OS tag, minus -custom-).
payload_to_image_nightly_whoami() {
    local ref=$1
    local release_ref=$2
    local nightly w repo
    w=$(whoami)
    if [[ -z "$ref" ]]; then
        echo "$ref"
        return
    fi
    if [[ "$ref" == *@* ]]; then
        echo "$ref"
        return
    fi
    if [[ -z "$release_ref" ]]; then
        err "PAYLOAD image tag needs a release ref (internal error)"
    fi
    nightly="$(nightly_tag_from_release_ref "$release_ref")"
    repo="$(image_repo_sans_tag_or_digest "$ref")"
    echo "${repo}:${nightly}-${w}"
}

# Resolve OCI ref @sha256 for use in oc adm after push (uses digest file or image inspect).
resolve_pushed_oci_ref() {
    local image_name=$1
    local digestfile=$2
    local d base
    d=""
    if [[ -f "$digestfile" && -s "$digestfile" ]]; then
        d=$(tr -d '\n\r' < "$digestfile")
    fi
    if [[ -n "$d" && "$d" = *'@sha256:'* ]]; then
        echo "$d"
        return
    fi
    if [[ -n "$d" && "$d" == sha256:* ]]; then
        base="$(image_repo_sans_tag_or_digest "$image_name")"
        echo "${base}@${d}"
        return
    fi
    if ! command -v podman >/dev/null 2>&1; then
        echo "Warning: could not read digest from file and podman is missing" >&2
        return
    fi
    podman image inspect --format '{{index .RepoDigests 0}}' "$image_name" 2>/dev/null || true
}

run_custom_os_build_and_push() {
    local release_ref=$1
    local authfile=$2
    local dockerfile_path=$3
    local build_ctx=$4
    local repo_base
    local oci_tag
    local full_name
    local digestfile

    if ! command -v podman >/dev/null 2>&1; then
        err "podman not in PATH; install podman or use --no-build"
    fi
    [[ -f "$dockerfile_path" ]] || err "Missing Dockerfile: ${dockerfile_path}"

    repo_base="$(image_repo_sans_tag_or_digest "${CUSTOM_OS_TO_IMAGE}")"
    oci_tag="$(oci_tag_nightly_custom "${release_ref}")"
    full_name="${repo_base}:${oci_tag}"

    local build_args=()
    if [[ -n "${EXPIRES_LABEL_VALUE:-}" ]]; then
        build_args+=(--label "quay.expires-after=${EXPIRES_LABEL_VALUE}")
    fi
    if [[ -n "${RA_REPO}" ]]; then
        build_args+=(--build-arg "RESOURCE_AGENTS_REPO=${RA_REPO}")
    fi
    if [[ -n "${RA_REF}" ]]; then
        build_args+=(--build-arg "RESOURCE_AGENTS_REF=${RA_REF}")
    fi
    echo "Running podman build (context: ${build_ctx}):"
    echo "  podman build --authfile ${authfile} ${build_args[*]} -f ${dockerfile_path} -t ${full_name} ${build_ctx}"
    podman build --authfile "$authfile" "${build_args[@]}" -f "$dockerfile_path" -t "$full_name" "$build_ctx"

    digestfile="$(mktemp "${TMPDIR:-/tmp}/tnf-custom-os-digest.XXXXXX")"
    echo "Pushing: ${full_name}"
    echo "  podman push --authfile ${authfile} --digestfile ${digestfile} ${full_name}"
    podman push --authfile "$authfile" --digestfile "$digestfile" "$full_name"

    BUILT_OCI_REF="$(resolve_pushed_oci_ref "$full_name" "$digestfile")" || BUILT_OCI_REF=""
    rm -f "$digestfile"
    if [[ -z "$BUILT_OCI_REF" ]]; then
        echo "" >&2
        echo "========================================================" >&2
        echo "WARNING: Push succeeded but digest could not be resolved." >&2
        echo "The 'oc adm release new' command below was NOT executed." >&2
        echo "Find your digest with:" >&2
        echo "  podman image inspect ${full_name} --format '{{index .RepoDigests 0}}'" >&2
        echo "Then run the printed command manually with your digest." >&2
        echo "========================================================" >&2
        echo "" >&2
    else
        echo "Pushed image ref: ${BUILT_OCI_REF}"
    fi
    echo "Tagged: ${oci_tag} (<nightly>-custom-<username>)"
}

# rhel-coreos (RHEL 9) -> stream9; rhel-coreos-10 (RHEL 10) -> stream10
base_stream_dockerfile() {
    case "$1" in
        rhel-coreos) echo "${SCRIPT_DIR}/Dockerfile.stream9" ;;
        rhel-coreos-10) echo "${SCRIPT_DIR}/Dockerfile.stream10" ;;
    esac
}

# First FROM in the Stream Dockerfiles is the CentOS build; name it for COPY --from= in the RHCOS stage.
STREAM_BUILD_STAGE="rpm_builder"

add_stream_build_stage_name() {
    local line first_from=0
    while IFS= read -r line || [[ -n "$line" ]]; do
        if [[ $first_from -eq 0 && "$line" =~ ^FROM[[:space:]] ]]; then
            if ! [[ "$line" =~ [[:space:]]AS[[:space:]] ]]; then
                line="${line} AS ${STREAM_BUILD_STAGE}"
            fi
            first_from=1
        fi
        printf '%s\n' "$line"
    done
}

write_dockerfile_custompayload() {
    local base_docker target
    local out=$1
    target="$(effective_target_component)"
    base_docker="$(base_stream_dockerfile "$BASE_OS")"
    [[ -f "$base_docker" ]] || err "Base Dockerfile not found: ${base_docker} (for --base-os ${BASE_OS})"
    {
        add_stream_build_stage_name < "$base_docker"
        printf '\n# --- Custom payload layer (appended by %s, target=%s) ---\n' "$SCRIPT_NAME" "$target"
        if is_extensions_target; then
            if [[ "$SKIP_OC" -eq 1 ]]; then
                print_dockerfile_extensions_placeholder "$AUTHFILE_REF" "$RELEASE_REF" "$target"
            else
                print_dockerfile_extensions_snippet "${OS_REF}"
            fi
        else
            if [[ "$SKIP_OC" -eq 1 ]]; then
                print_dockerfile_placeholder "$AUTHFILE_REF" "$RELEASE_REF" "$target"
            else
                print_dockerfile_snippet "${OS_REF}"
            fi
        fi
    } > "$out"
    echo "Wrote ${out} (from $(basename "$base_docker") + ${target} snippet)"
}

# Second build stage: RHCOS base. RPM comes from the Stream stage in /tmp/ (see Dockerfile.stream*).
print_dockerfile_snippet() {
    local os_ref=$1
    cat <<EOF
# Multi-stage: previous stage is ${STREAM_BUILD_STAGE} (Stream build); it leaves the RPM at /tmp/${RPM_FILENAME}.
FROM ${os_ref}

COPY --from=${STREAM_BUILD_STAGE} /tmp/${RPM_FILENAME} /${RPM_FILENAME}

RUN test -s /${RPM_FILENAME} || \
    (echo 'ERROR: ${RPM_FILENAME} is empty (Stream 10 cannot build RPMs until libqb-devel is in EPEL 10). Use --base-os rhel-coreos for Stream 9.' && exit 1)
RUN rpm-ostree -C override replace /${RPM_FILENAME} && rm -f /${RPM_FILENAME}
EOF
}

print_dockerfile_placeholder() {
    local auth=$1
    local release_ref=$2
    local base_os=$3
    cat <<EOF
# Multi-stage: previous stage is ${STREAM_BUILD_STAGE} (Stream build); it leaves the RPM at /tmp/${RPM_FILENAME}.
# (oc was skipped) Set the next FROM to the one-line output of:
#   oc adm release info -a ${auth} --image-for=${base_os} ${release_ref}
FROM localhost/REPLACE-WITH-OUTPUT-OF-OC-ADM-RELEASE-INFO-ABOVE

COPY --from=${STREAM_BUILD_STAGE} /tmp/${RPM_FILENAME} /${RPM_FILENAME}
RUN test -s /${RPM_FILENAME} || \
    (echo 'ERROR: ${RPM_FILENAME} is empty (Stream 10 cannot build RPMs until libqb-devel is in EPEL 10). Use --base-os rhel-coreos for Stream 9.' && exit 1)
RUN rpm-ostree -C override replace /${RPM_FILENAME} && rm -f /${RPM_FILENAME}
EOF
}

print_dockerfile_extensions_snippet() {
    local ext_ref=$1
    cat <<EOF
# Multi-stage: previous stage is ${STREAM_BUILD_STAGE} (Stream build); it leaves the RPM at /tmp/${RPM_FILENAME}.
# Extensions overlay: replace the RPM and regenerate repodata so rpm-ostree sees
# consistent NVR metadata. Without this, the ostree refspec derived from stale
# repodata won't match the replacement RPM's internal NVR.
FROM ${ext_ref} AS extensions_base

FROM quay.io/centos/centos:stream9 AS extensions_repodata
RUN dnf install -y createrepo_c && dnf clean all
COPY --from=extensions_base /usr/share/rpm-ostree/extensions/ /extensions/
COPY --from=${STREAM_BUILD_STAGE} /tmp/${RPM_FILENAME} /tmp/resource-agents-custom.rpm

RUN cd /extensions/ \
    && ORIG=\$(ls resource-agents-[0-9]*.rpm 2>/dev/null | head -1) \
    && if [ -n "\$ORIG" ]; then cp /tmp/resource-agents-custom.rpm "\$ORIG"; \
       else cp /tmp/resource-agents-custom.rpm ${RPM_FILENAME}; fi \
    && rm -f /tmp/resource-agents-custom.rpm \
    && rm -rf repodata/ \
    && createrepo_c .

FROM ${ext_ref}
COPY --from=extensions_repodata /extensions/ /usr/share/rpm-ostree/extensions/
EOF
}

print_dockerfile_extensions_placeholder() {
    local auth=$1
    local release_ref=$2
    local target=$3
    cat <<EOF
# Multi-stage: previous stage is ${STREAM_BUILD_STAGE} (Stream build); it leaves the RPM at /tmp/${RPM_FILENAME}.
# Extensions overlay: replace the RPM and regenerate repodata so rpm-ostree sees
# consistent NVR metadata. Without this, the ostree refspec derived from stale
# repodata won't match the replacement RPM's internal NVR.
# (oc was skipped) Set extensions_base FROM to the one-line output of:
#   oc adm release info -a ${auth} --image-for=${target} ${release_ref}
FROM localhost/REPLACE-WITH-OUTPUT-OF-OC-ADM-RELEASE-INFO-ABOVE AS extensions_base

FROM quay.io/centos/centos:stream9 AS extensions_repodata
RUN dnf install -y createrepo_c && dnf clean all
COPY --from=extensions_base /usr/share/rpm-ostree/extensions/ /extensions/
COPY --from=${STREAM_BUILD_STAGE} /tmp/${RPM_FILENAME} /tmp/resource-agents-custom.rpm

RUN cd /extensions/ \
    && ORIG=\$(ls resource-agents-[0-9]*.rpm 2>/dev/null | head -1) \
    && if [ -n "\$ORIG" ]; then cp /tmp/resource-agents-custom.rpm "\$ORIG"; \
       else cp /tmp/resource-agents-custom.rpm ${RPM_FILENAME}; fi \
    && rm -f /tmp/resource-agents-custom.rpm \
    && rm -rf repodata/ \
    && createrepo_c .

# Final stage: same base as extensions_base (replace FROM below with same image)
FROM localhost/REPLACE-WITH-OUTPUT-OF-OC-ADM-RELEASE-INFO-ABOVE
COPY --from=extensions_repodata /extensions/ /usr/share/rpm-ostree/extensions/
EOF
}

print_release_new_cmd() {
    local auth=$1
    local from_release=$2
    local to_payload_image=$3
    local component=$4
    local custom_ref=$5
    local mapping

    if [[ -z "$custom_ref" ]]; then
        mapping="${component}=${CUSTOM_OS_TO_IMAGE}@sha256:YOUR_BUILD_DIGEST"
    else
        mapping="${component}=${custom_ref}"
    fi

    if [[ "$SKIP_OC" -eq 1 ]]; then
        echo "(--print-only / --skip-oc) Run when ready:"
        echo "  oc adm release new -a ${auth} \\"
        echo "    --from-release ${from_release} \\"
        echo "    --to-image ${to_payload_image} \\"
        echo "    ${mapping}"
        return
    fi

    if ! command -v oc >/dev/null 2>&1; then
        err "oc is not in PATH; cannot run oc adm release new (install the OpenShift client or use --print-only)"
    fi

    if [[ -z "$custom_ref" || "$custom_ref" == *"YOUR_BUILD_DIGEST"* ]]; then
        echo "No custom OS image ref yet; build without --no-build or pass --custom-os, then run:"
        echo "  oc adm release new -a ${auth} \\"
        echo "    --from-release ${from_release} \\"
        echo "    --to-image ${to_payload_image} \\"
        echo "    ${mapping}"
        return
    fi

    echo "Running: oc adm release new --to-image ${to_payload_image} (${mapping})"
    oc adm release new -a "$auth" \
        --from-release "$from_release" \
        --to-image "$to_payload_image" \
        "${mapping}"
    relabel_pushed_payload_with_quay_expires "$to_payload_image" "$auth" "$EXPIRES_LABEL_VALUE"
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --release)
            [[ -n "${2:-}" && "$2" != -* ]] || err "--release requires a pullspec"
            RELEASE_REF="$2"
            shift 2
            ;;
        --auto-release) USE_AUTO_RELEASE=1; shift ;;
        -a | --authfile)
            [[ -n "${2:-}" && "$2" != -* ]] || err "-a / --authfile requires a path"
            AUTHFILE="$2"
            shift 2
            ;;
        --base-os)
            [[ -n "${2:-}" && "$2" != -* ]] || err "--base-os requires a value"
            BASE_OS="$2"
            shift 2
            ;;
        --to-os-image)
            [[ -n "${2:-}" && "$2" != -* ]] || err "--to-os-image requires a value"
            CUSTOM_OS_TO_IMAGE="$2"
            shift 2
            ;;
        --to-payload-image)
            [[ -n "${2:-}" && "$2" != -* ]] || err "--to-payload-image requires a value"
            PAYLOAD_TO_IMAGE="$2"
            shift 2
            ;;
        --to-image)
            [[ -n "${2:-}" && "$2" != -* ]] || err "--to-image requires a value"
            PAYLOAD_TO_IMAGE="$2"
            shift 2
            ;;
        --custom-os)
            [[ -n "${2:-}" && "$2" != -* ]] || err "--custom-os requires a value"
            CUSTOM_OS_IMAGE_REF="$2"
            shift 2
            ;;
        --target-component)
            [[ -n "${2:-}" && "$2" != -* ]] || err "--target-component requires a value"
            TARGET_COMPONENT="$2"
            shift 2
            ;;
        --repo)
            [[ -n "${2:-}" && "$2" != -* ]] || err "--repo requires a URL"
            RA_REPO="$2"
            shift 2
            ;;
        --ref)
            [[ -n "${2:-}" && "$2" != -* ]] || err "--ref requires a value"
            RA_REF="$2"
            shift 2
            ;;
        --rpm-filename)
            [[ -n "${2:-}" && "$2" != -* ]] || err "--rpm-filename requires a value"
            RPM_FILENAME="$2"
            shift 2
            ;;
        --quay-expires-after)
            [[ -n "${2:-}" && "$2" != -* ]] || err "--quay-expires-after requires a value (e.g. 24h, 7d, none)"
            QUAY_EXPIRES_AFTER_OVERRIDE="$2"
            shift 2
            ;;
        --print-only) SKIP_OC=1; SKIP_PODMAN_BUILD=1; shift ;;
        --skip-oc) SKIP_OC=1; shift ;;
        --no-build) SKIP_PODMAN_BUILD=1; shift ;;
        -h | --help) usage 0 ;;
        *)
            err "Unknown option: $1 (try --help)"
            ;;
    esac
done

# Cannot build the RHCOS layer without a resolved base image from oc.
if [[ "$SKIP_OC" -eq 1 ]]; then
    SKIP_PODMAN_BUILD=1
fi

validate_base_os "$BASE_OS"
if [[ -n "$TARGET_COMPONENT" ]]; then
    validate_target_component "$TARGET_COMPONENT"
fi

if [[ -z "$RELEASE_REF" && "$USE_AUTO_RELEASE" -ne 1 ]]; then
    err "Specify --release PULLSPEC or --auto-release"
fi
if [[ -n "$RELEASE_REF" && "$USE_AUTO_RELEASE" -eq 1 ]]; then
    err "Use only one of --release or --auto-release"
fi

EXPIRES_LABEL_VALUE="$(resolve_quay_expires_label)"

if [[ "$USE_AUTO_RELEASE" -eq 1 ]]; then
    RELEASE_REF="$(fetch_auto_release_pullspec)"
    echo "Using newest Accepted 5.0.0-0.nightly payload:"
    echo "  ${RELEASE_REF}"
    echo ""
else
    echo "Using release payload:"
    echo "  ${RELEASE_REF}"
    echo ""
fi

PAYLOAD_TO_IMAGE="$(payload_to_image_nightly_whoami "${PAYLOAD_TO_IMAGE}" "${RELEASE_REF}")"

# Only resolve a real on-disk pull secret when oc/podman will use it. --print-only
# and --skip-oc run without a local pull secret; placeholders use AUTHFILE_REF.
AUTHFILE_RESOLVED=""
AUTHFILE_REF=""
if [[ "$SKIP_OC" -eq 0 ]]; then
    AUTHFILE_RESOLVED="$(resolve_default_authfile)"
    AUTHFILE_REF="${AUTHFILE_RESOLVED}"
    echo "Pull secret (oc -a / podman --authfile):"
    echo "  ${AUTHFILE_RESOLVED}"
else
    if [[ -n "$AUTHFILE" ]]; then
        AUTHFILE_REF="${AUTHFILE}"
    else
        AUTHFILE_REF="<PULL_SECRET or -a path>"
    fi
    echo "Pull secret (oc -a / podman --authfile):"
    if [[ -n "$AUTHFILE" ]]; then
        echo "  (not read in --print-only / --skip-oc) example commands and Dockerfile use: ${AUTHFILE}"
    else
        echo "  (not read in --print-only / --skip-oc; use a real -a or default auth for full builds)"
    fi
fi
if [[ -n "$EXPIRES_LABEL_VALUE" ]]; then
    echo "Quay label quay.expires-after: ${EXPIRES_LABEL_VALUE}"
else
    echo "Quay label quay.expires-after: (disabled)"
fi
if [[ -n "${RA_REPO}" || -n "${RA_REF}" ]]; then
    echo "Resource agents source:"
    echo "  Repo: ${RA_REPO:-<default: upstream>}"
    echo "  Ref:  ${RA_REF:-<default: main>}"
fi
if [[ -n "$TARGET_COMPONENT" ]]; then
    echo "Target component: ${TARGET_COMPONENT} (overrides default: ${BASE_OS})"
    if is_extensions_target; then
        echo "  Mode: extensions overlay (RPM file replacement, not rpm-ostree)"
    fi
fi
echo ""

RESOLVED_TARGET="$(effective_target_component)"
OS_REF=""
if [[ "$SKIP_OC" -eq 0 ]]; then
    if ! command -v oc >/dev/null 2>&1; then
        err "oc is not in PATH. Install OpenShift client or use --print-only to skip"
    fi
    echo "Resolving target image (oc adm release info -a ... ${RELEASE_REF} --image-for ${RESOLVED_TARGET}):"
    oc_release_info_err=$(mktemp) || err "mktemp failed"
    if ! OS_REF="$(oc adm release info -a "$AUTHFILE_RESOLVED" --image-for="$RESOLVED_TARGET" "$RELEASE_REF" 2>"$oc_release_info_err")"; then
        oc_stderr_out=$(tr -d '\0' < "$oc_release_info_err")
        rm -f "$oc_release_info_err"
        detail=""
        [[ -n "$oc_stderr_out" ]] && detail=$'\n\n'"oc stderr:"$'\n'"$oc_stderr_out"
        if [[ "$RESOLVED_TARGET" == "rhel-coreos-10" ]]; then
            err "oc adm release info failed. Try --base-os rhel-coreos if this release uses RHEL 9 (rhel-coreos).${detail}"
        fi
        err "oc adm release info failed for target ${RESOLVED_TARGET}. Check pull secret and payload.${detail}"
    fi
    rm -f "$oc_release_info_err"
    # Trim whitespace
    OS_REF="${OS_REF//$'\r'/}"
    OS_REF="${OS_REF//$'\n'/}"
    echo "  ${OS_REF}"
    echo ""
fi

if [[ "$SKIP_OC" -eq 1 ]]; then
    echo "Skipping oc. Resolve the target image with:"
    echo "  oc adm release info -a ${AUTHFILE_REF} --image-for=${RESOLVED_TARGET} ${RELEASE_REF}"
    echo ""
fi

write_dockerfile_custompayload "${OUT_DOCKERFILE}"
echo ""

BUILT_OCI_REF=""
if [[ "$SKIP_PODMAN_BUILD" -eq 1 ]]; then
    echo "Skipping podman build ( --no-build, or oc skipped with --print-only / --skip-oc )."
    echo "Generated Dockerfile: ${OUT_DOCKERFILE}"
    echo ""
else
    run_custom_os_build_and_push "$RELEASE_REF" "$AUTHFILE_RESOLVED" "$OUT_DOCKERFILE" "$SCRIPT_DIR"
    echo ""
fi

cat <<EOF
--- Custom payload: oc adm release new (uses --to-payload-image) ---

  PAYLOAD --to-image: ${PAYLOAD_TO_IMAGE}
  ${RESOLVED_TARGET} mapping: ${CUSTOM_OS_IMAGE_REF:-${BUILT_OCI_REF:-<set --custom-os or run build without --no-build>}}

EOF

EFFECTIVE_OS_REF="${CUSTOM_OS_IMAGE_REF:-$BUILT_OCI_REF}"
print_release_new_cmd "$AUTHFILE_REF" "$RELEASE_REF" "$PAYLOAD_TO_IMAGE" "$RESOLVED_TARGET" "$EFFECTIVE_OS_REF"
echo ""

cat <<EOF

Reference: 5.0 nightlies and artifacts index at https://amd64.ocp.releases.ci.openshift.org/
API: ${API_5_NIGHTLY_URL}
EOF
