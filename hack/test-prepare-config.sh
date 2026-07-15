#!/usr/bin/bash
# Offline test matrix for prepare-config.sh and resolve-release-image.sh.
# Runs without network access — validates config transforms against real examples.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

readonly PREPARE="${REPO_ROOT}/helpers/prepare-config.sh"
readonly RESOLVE="${REPO_ROOT}/helpers/resolve-release-image.sh"

PASS=0
FAIL=0
TMPDIR_BASE=""

readonly COLOR_RED='\033[0;31m'
readonly COLOR_GREEN='\033[0;32m'
readonly COLOR_CLEAR='\033[0m'

pass() { echo -e "${COLOR_GREEN}  PASS${COLOR_CLEAR} $1"; PASS=$((PASS + 1)); }
fail() { echo -e "${COLOR_RED}  FAIL${COLOR_CLEAR} $1"; FAIL=$((FAIL + 1)); }

setup() {
    TMPDIR_BASE=$(mktemp -d)
    trap 'rm -rf "$TMPDIR_BASE"' EXIT
}

# ---------------------------------------------------------------------------
# Assert helpers
# ---------------------------------------------------------------------------

assert_exit() {
    local expected="$1" actual="$2" label="$3"
    if [[ "$expected" == "$actual" ]]; then
        pass "$label (exit $expected)"
    else
        fail "$label (expected exit $expected, got $actual)"
    fi
}

assert_grep() {
    local file="$1" pattern="$2" label="$3"
    if grep -qE "$pattern" "$file"; then
        pass "$label"
    else
        fail "$label — pattern not found: $pattern"
    fi
}

assert_not_grep() {
    local file="$1" pattern="$2" label="$3"
    if ! grep -qE "$pattern" "$file"; then
        pass "$label"
    else
        fail "$label — pattern should not match: $pattern"
    fi
}

# ---------------------------------------------------------------------------
# Run prepare-config.sh and capture result
# ---------------------------------------------------------------------------

run_prepare() {
    local label="$1"; shift
    local outfile="${TMPDIR_BASE}/${label}.sh"
    local rc=0
    "$PREPARE" --output "$outfile" "$@" >/dev/null 2>&1 || rc=$?
    echo "$outfile:$rc"
}

# ---------------------------------------------------------------------------
# Test: config transform matrix
# ---------------------------------------------------------------------------

test_transform_matrix() {
    echo "=== Config transform matrix ==="

    local topologies=(arbiter fencing sno)
    local methods=(ipi agent)
    local arches=(x86_64 aarch64)
    local stacks=(v4 v6 v4v6)

    # shellcheck disable=SC2034
    local prefix_map_arbiter="TNA"
    # shellcheck disable=SC2034
    local prefix_map_fencing="TNF"
    # shellcheck disable=SC2034
    local prefix_map_sno="SNO"

    local ci_token="sha256~test_matrix_token_abc123"

    for topo in "${topologies[@]}"; do
        local prefix_var="prefix_map_${topo}"
        local expected_prefix="${!prefix_var}"

        for method in "${methods[@]}"; do
            for arch in "${arches[@]}"; do
                local image
                if [[ "$arch" == "aarch64" ]]; then
                    image="quay.io/openshift-release-dev/ocp-release:4.21.0-aarch64"
                else
                    image="quay.io/openshift-release-dev/ocp-release:4.21.0-multi"
                fi

                for stack in "${stacks[@]}"; do
                    local label="${topo}_${method}_${arch}_${stack}"

                    # Constraint: aarch64 + non-v4 → exit 3
                    if [[ "$arch" == "aarch64" && "$stack" != "v4" ]]; then
                        local rc=0
                        "$PREPARE" --topology "$topo" --method "$method" \
                            --release-image "$image" --ci-token "$ci_token" \
                            --arch "$arch" --ip-stack "$stack" \
                            --output "${TMPDIR_BASE}/${label}.sh" >/dev/null 2>&1 || rc=$?
                        assert_exit 3 "$rc" "$label (aarch64+${stack} blocked)"
                        continue
                    fi

                    local result
                    result=$(run_prepare "$label" \
                        --topology "$topo" --method "$method" \
                        --release-image "$image" --ci-token "$ci_token" \
                        --arch "$arch" --ip-stack "$stack")
                    local outfile="${result%%:*}"
                    local rc="${result##*:}"

                    assert_exit 0 "$rc" "$label"
                    [[ "$rc" -eq 0 ]] || continue

                    # Scenario prefix matches topology
                    local ip_suffix
                    case "$stack" in
                        v4)   ip_suffix="IPV4" ;;
                        v6)   ip_suffix="IPV6" ;;
                        v4v6) ip_suffix="IPV4V6" ;;
                    esac
                    assert_grep "$outfile" "^export AGENT_E2E_TEST_SCENARIO=\"${expected_prefix}_${ip_suffix}\"" \
                        "$label scenario=${expected_prefix}_${ip_suffix}"

                    # No <PASTE placeholder
                    assert_not_grep "$outfile" '<PASTE' "$label no placeholder"

                    # Source succeeds
                    # shellcheck disable=SC1090
                    if ( source "$outfile" ) 2>/dev/null; then
                        pass "$label sourceable"
                    else
                        fail "$label sourceable"
                    fi

                    # aarch64: Metal3 images uncommented
                    if [[ "$arch" == "aarch64" ]]; then
                        assert_grep "$outfile" '^[[:space:]]*export IRONIC_IMAGE=' "$label IRONIC_IMAGE active"
                        assert_grep "$outfile" '^[[:space:]]*export VBMC_IMAGE=' "$label VBMC_IMAGE active"
                        assert_grep "$outfile" '^[[:space:]]*export SUSHY_TOOLS_IMAGE=' "$label SUSHY_TOOLS active"
                    fi

                    # OPENSHIFT_CI not active
                    assert_not_grep "$outfile" '^export OPENSHIFT_CI=' "$label OPENSHIFT_CI commented"

                    # CI_TOKEN active
                    assert_grep "$outfile" '^export CI_TOKEN="sha256~' "$label CI_TOKEN active"

                    # Release image set
                    assert_grep "$outfile" "^export OPENSHIFT_RELEASE_IMAGE=${image}" "$label release image"

                    # IP_STACK set
                    assert_grep "$outfile" "^export IP_STACK=\"${stack}\"" "$label IP_STACK"
                done
            done
        done
    done
}

# ---------------------------------------------------------------------------
# Test: constraint blocks and usage errors
# ---------------------------------------------------------------------------

test_constraints() {
    echo ""
    echo "=== Constraint and usage tests ==="

    local ci="sha256~constraint_test"
    local img="quay.io/openshift-release-dev/ocp-release:4.21.0-multi"

    # aarch64 + -multi image → exit 3
    local rc=0
    "$PREPARE" --topology fencing --method ipi --release-image "$img" \
        --ci-token "$ci" --arch aarch64 \
        --output "${TMPDIR_BASE}/blocked_multi.sh" >/dev/null 2>&1 || rc=$?
    assert_exit 3 "$rc" "aarch64 + -multi blocked"

    # Missing --ci-token → exit 2
    rc=0
    "$PREPARE" --topology fencing --method ipi --release-image "$img" \
        --output "${TMPDIR_BASE}/no_token.sh" >/dev/null 2>&1 || rc=$?
    assert_exit 2 "$rc" "missing --ci-token"

    # Existing output without --force → exit 4
    touch "${TMPDIR_BASE}/exists.sh"
    rc=0
    "$PREPARE" --topology fencing --method ipi --release-image "$img" \
        --ci-token "$ci" --output "${TMPDIR_BASE}/exists.sh" >/dev/null 2>&1 || rc=$?
    assert_exit 4 "$rc" "existing output without --force"

    # --force overwrites and creates backup
    rc=0
    "$PREPARE" --topology fencing --method ipi --release-image "$img" \
        --ci-token "$ci" --output "${TMPDIR_BASE}/exists.sh" --force >/dev/null 2>&1 || rc=$?
    assert_exit 0 "$rc" "--force overwrites"
    if [[ -f "${TMPDIR_BASE}/exists.sh.bak" ]]; then
        pass "--force creates .bak"
    else
        fail "--force creates .bak"
    fi

    # --help exits 0 (prepare-config)
    rc=0
    "$PREPARE" --help >/dev/null 2>&1 || rc=$?
    assert_exit 0 "$rc" "prepare-config --help"

    # --help exits 0 (resolve-release-image)
    rc=0
    "$RESOLVE" --help >/dev/null 2>&1 || rc=$?
    assert_exit 0 "$rc" "resolve-release-image --help"

    # Invalid version spec → exit 2
    rc=0
    "$RESOLVE" --version garbage >/dev/null 2>&1 || rc=$?
    assert_exit 2 "$rc" "resolver rejects garbage spec"

    # --ds-branch without --ds-repo → exit 2
    rc=0
    "$PREPARE" --topology fencing --method ipi --release-image "$img" \
        --ci-token "$ci" --ds-branch mybranch \
        --output "${TMPDIR_BASE}/ds_branch_only.sh" >/dev/null 2>&1 || rc=$?
    assert_exit 2 "$rc" "--ds-branch without --ds-repo"
}

# ---------------------------------------------------------------------------
# Test: inventory.ini fork handling
# ---------------------------------------------------------------------------

test_inventory() {
    echo ""
    echo "=== Inventory fork handling ==="

    local ci="sha256~inv_test"
    local img="quay.io/openshift-release-dev/ocp-release:4.21.0-multi"
    local inv="${TMPDIR_BASE}/inventory.ini"

    # Create test inventory
    cat > "$inv" <<'INV'
[metal_machine]
user@host ansible_ssh_extra_args='-o ServerAliveInterval=30'

[metal_machine:vars]
ansible_become_password=""
INV

    # --ds-repo + --ds-branch → upserts both
    "$PREPARE" --topology fencing --method ipi --release-image "$img" \
        --ci-token "$ci" --inventory "$inv" \
        --ds-repo https://github.com/user/dev-scripts --ds-branch fix/my-change \
        --output "${TMPDIR_BASE}/inv1.sh" >/dev/null 2>&1
    assert_grep "$inv" '^dev_scripts_src_repo=https://github.com/user/dev-scripts' "upsert repo"
    assert_grep "$inv" '^dev_scripts_branch=fix/my-change' "upsert branch"

    # --ds-repo only → upserts repo + default branch=master
    "$PREPARE" --topology fencing --method ipi --release-image "$img" \
        --ci-token "$ci" --inventory "$inv" \
        --ds-repo https://github.com/other/dev-scripts \
        --output "${TMPDIR_BASE}/inv2.sh" --force >/dev/null 2>&1
    assert_grep "$inv" '^dev_scripts_src_repo=https://github.com/other/dev-scripts' "repo-only upsert"
    assert_grep "$inv" '^dev_scripts_branch=master' "repo-only defaults branch=master"

    # Neither → purges existing lines
    "$PREPARE" --topology fencing --method ipi --release-image "$img" \
        --ci-token "$ci" --inventory "$inv" \
        --output "${TMPDIR_BASE}/inv3.sh" --force >/dev/null 2>&1
    assert_not_grep "$inv" '^dev_scripts_src_repo=' "purged repo"
    assert_not_grep "$inv" '^dev_scripts_branch=' "purged branch"

    # Missing inventory.ini + --ds-repo → error
    local rc=0
    "$PREPARE" --topology fencing --method ipi --release-image "$img" \
        --ci-token "$ci" --inventory "${TMPDIR_BASE}/nonexistent.ini" \
        --ds-repo https://github.com/user/dev-scripts \
        --output "${TMPDIR_BASE}/inv4.sh" >/dev/null 2>&1 || rc=$?
    if [[ "$rc" -ne 0 ]]; then
        pass "missing inventory + --ds-repo errors"
    else
        fail "missing inventory + --ds-repo should error"
    fi
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

setup
test_transform_matrix
test_constraints
test_inventory

echo ""
echo "=============================="
echo -e "Results: ${COLOR_GREEN}${PASS} passed${COLOR_CLEAR}, ${COLOR_RED}${FAIL} failed${COLOR_CLEAR}"
echo "=============================="

[[ "$FAIL" -eq 0 ]]
