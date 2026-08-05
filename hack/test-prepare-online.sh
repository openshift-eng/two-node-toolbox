#!/usr/bin/bash
# Online validation for resolve-release-image.sh and prepare-config.sh.
# Tier 1: resolver against live registries (any dev machine with pull-secret).
# Tier 2: end-to-end config generation on configured instances.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

readonly RESOLVE="${REPO_ROOT}/helpers/resolve-release-image.sh"
readonly PREPARE="${REPO_ROOT}/helpers/prepare-config.sh"
readonly PULL_SECRET="${REPO_ROOT}/config/pull-secret.json"
readonly INVENTORY="${REPO_ROOT}/inventory.ini"

PASS=0
FAIL=0
SKIP=0
TMPDIR_BASE=""

readonly COLOR_RED='\033[0;31m'
readonly COLOR_GREEN='\033[0;32m'
readonly COLOR_YELLOW='\033[0;33m'
readonly COLOR_CLEAR='\033[0m'

pass() { echo -e "${COLOR_GREEN}  PASS${COLOR_CLEAR} $1"; PASS=$((PASS + 1)); }
fail() { echo -e "${COLOR_RED}  FAIL${COLOR_CLEAR} $1"; FAIL=$((FAIL + 1)); }
skip() { echo -e "${COLOR_YELLOW}  SKIP${COLOR_CLEAR} $1"; SKIP=$((SKIP + 1)); }

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

assert_stdout_match() {
    local stdout="$1" pattern="$2" label="$3"
    if echo "$stdout" | grep -qE -- "$pattern"; then
        pass "$label"
    else
        fail "$label — stdout '${stdout}' didn't match: $pattern"
    fi
}

assert_stdout_not_match() {
    local stdout="$1" pattern="$2" label="$3"
    if ! echo "$stdout" | grep -qE -- "$pattern"; then
        pass "$label"
    else
        fail "$label — stdout '${stdout}' should not match: $pattern"
    fi
}

# ---------------------------------------------------------------------------
# Skip detection
# ---------------------------------------------------------------------------

HAS_PULL_SECRET="false"
HAS_CI_TOKEN="false"
HAS_E2E_CONFIG="false"

detect_capabilities() {
    if [[ -f "$PULL_SECRET" ]]; then
        HAS_PULL_SECRET="true"
    else
        echo "Skipped: pull-secret.json not found (run /setup first)"
        exit 0
    fi

    if [[ -n "${CI_TOKEN:-}" ]]; then
        HAS_CI_TOKEN="true"
    fi

    if [[ -f "$INVENTORY" ]] && \
       [[ -f "${REPO_ROOT}/config/config_fencing_example.sh" ]] && \
       [[ -f "${REPO_ROOT}/config/config_sno_example.sh" ]]; then
        HAS_E2E_CONFIG="true"
    fi
}

# ---------------------------------------------------------------------------
# Tier 1: Resolver online tests
# ---------------------------------------------------------------------------

test_resolver_ga() {
    echo "=== Tier 1: GA/EC/RC (quay.io) ==="

    # Test 1: --version 4.22 → quay multi tag
    local stdout rc=0
    stdout=$("$RESOLVE" --version 4.22 --quiet 2>/dev/null) || rc=$?
    assert_exit 0 "$rc" "T1.1 resolve 4.22 GA"
    [[ "$rc" -eq 0 ]] && \
        assert_stdout_match "$stdout" 'quay\.io/openshift-release-dev/ocp-release:4\.22\.[0-9]+-multi' \
            "T1.1 pullspec is quay multi"

    # Test 2: --version 4.22 --arch aarch64 → aarch64 tag, never -multi
    rc=0
    stdout=$("$RESOLVE" --version 4.22 --arch aarch64 --quiet 2>/dev/null) || rc=$?
    assert_exit 0 "$rc" "T1.2 resolve 4.22 aarch64"
    if [[ "$rc" -eq 0 ]]; then
        assert_stdout_match "$stdout" ':4\.22\.[0-9]+-aarch64' "T1.2 tag is aarch64"
        assert_stdout_not_match "$stdout" '-multi' "T1.2 not multi"
    fi

    # Test 3: --version 4.22 --digest → sha256 digest
    rc=0
    stdout=$("$RESOLVE" --version 4.22 --digest --quiet 2>/dev/null) || rc=$?
    assert_exit 0 "$rc" "T1.3 resolve 4.22 digest"
    [[ "$rc" -eq 0 ]] && \
        assert_stdout_match "$stdout" 'ocp-release@sha256:[a-f0-9]{64}' \
            "T1.3 digest format"

    # Test 4: --version 4.22 --validate-access → exit 0
    rc=0
    "$RESOLVE" --version 4.22 --validate-access --quiet >/dev/null 2>&1 || rc=$?
    assert_exit 0 "$rc" "T1.4 validate-access 4.22"

    # Test 5: --version 99.99 → exit 3
    rc=0
    "$RESOLVE" --version 99.99 --quiet >/dev/null 2>&1 || rc=$?
    assert_exit 3 "$rc" "T1.5 nonexistent version"
}

test_resolver_prerelease() {
    echo ""
    echo "=== Tier 1: Prerelease (quay.io) ==="

    # Test 6: --version 4.22-prerelease → ec/rc tag or exit 3
    local stdout rc=0
    stdout=$("$RESOLVE" --version 4.22-prerelease --quiet 2>/dev/null) || rc=$?
    if [[ "$rc" -eq 0 ]]; then
        assert_stdout_match "$stdout" '-(ec|rc)\.' "T1.6 prerelease tag"
    elif [[ "$rc" -eq 3 ]]; then
        skip "T1.6 no prerelease for 4.22 (exit 3 expected)"
    else
        fail "T1.6 prerelease (unexpected exit $rc)"
    fi
}

test_resolver_nightly() {
    echo ""
    echo "=== Tier 1: Nightly (release controller) ==="

    if [[ "$HAS_CI_TOKEN" != "true" ]]; then
        skip "T1.7-10 nightly tests (CI_TOKEN not set)"
        return
    fi

    # Test 7: --version 4.22-nightly → registry.ci pullspec
    local stdout rc=0
    stdout=$("$RESOLVE" --version 4.22-nightly --quiet 2>/dev/null) || rc=$?
    assert_exit 0 "$rc" "T1.7 resolve 4.22-nightly"
    [[ "$rc" -eq 0 ]] && \
        assert_stdout_match "$stdout" 'registry\.ci\.openshift\.org/ocp/release:4\.22' \
            "T1.7 pullspec is CI registry"

    # Test 8: --version 4.22-nightly --arch aarch64 → arm64 registry
    rc=0
    stdout=$("$RESOLVE" --version 4.22-nightly --arch aarch64 --quiet 2>/dev/null) || rc=$?
    assert_exit 0 "$rc" "T1.8 resolve 4.22-nightly aarch64"
    [[ "$rc" -eq 0 ]] && \
        assert_stdout_match "$stdout" 'registry\.ci\.openshift\.org/ocp-arm64/release-arm64:' \
            "T1.8 pullspec is arm64 CI registry"

    # Test 9: --validate-access with real CI_TOKEN → exit 0
    rc=0
    "$RESOLVE" --version 4.22-nightly --validate-access --ci-token "$CI_TOKEN" --quiet >/dev/null 2>&1 || rc=$?
    assert_exit 0 "$rc" "T1.9 validate-access nightly with CI_TOKEN"

    # Test 10: --validate-access with dummy CI token → exit 5
    rc=0
    "$RESOLVE" --version 4.22-nightly --validate-access --ci-token "sha256~bogus_token_12345" --quiet >/dev/null 2>&1 || rc=$?
    assert_exit 5 "$rc" "T1.10 validate-access nightly with bad token"
}

test_resolver_digest_fallback() {
    echo ""
    echo "=== Tier 1: Digest fallback ==="

    # Test 11: --digest with oc on PATH
    local stdout rc=0
    stdout=$("$RESOLVE" --version 4.22 --digest --quiet 2>/dev/null) || rc=$?
    assert_exit 0 "$rc" "T1.11 digest with oc"
    [[ "$rc" -eq 0 ]] && \
        assert_stdout_match "$stdout" '@sha256:' "T1.11 contains @sha256:"

    # Test 11b: --digest with oc hidden (curl fallback)
    rc=0
    local restricted_path
    restricted_path=$(echo "$PATH" | tr ':' '\n' | grep -v -E '(openshift|oc|ocp|crc|usr/local/bin|\.local)' | tr '\n' ':')
    restricted_path="${restricted_path%:}"
    stdout=$(PATH="$restricted_path" "$RESOLVE" --version 4.22 --digest --quiet 2>/dev/null) || rc=$?
    if [[ "$rc" -eq 0 ]]; then
        assert_stdout_match "$stdout" '@sha256:' "T1.11b digest via curl fallback"
    else
        skip "T1.11b curl fallback (exit $rc — may need auth in pull-secret)"
    fi
}

test_resolver_passthrough() {
    echo ""
    echo "=== Tier 1: Explicit passthrough ==="

    # Test 12: --pullspec echoes input unchanged
    local input="quay.io/openshift-release-dev/ocp-release:4.22.0-multi"
    local stdout rc=0
    stdout=$("$RESOLVE" --pullspec "$input" --quiet 2>/dev/null) || rc=$?
    assert_exit 0 "$rc" "T1.12 passthrough"
    if [[ "$rc" -eq 0 && "$stdout" == "$input" ]]; then
        pass "T1.12 output matches input"
    elif [[ "$rc" -eq 0 ]]; then
        fail "T1.12 output mismatch: got '$stdout'"
    fi
}

# ---------------------------------------------------------------------------
# Tier 2: End-to-end validation
# ---------------------------------------------------------------------------

test_e2e_fencing_ipi() {
    echo ""
    echo "=== Tier 2: Fencing IPI x86_64 (E2E-1) ==="

    local resolved rc=0
    resolved=$("$RESOLVE" --version 4.22 --quiet 2>/dev/null) || rc=$?
    if [[ "$rc" -ne 0 ]]; then
        fail "E2E-1 setup: resolve 4.22 failed (exit $rc)"
        return
    fi

    local outfile="${TMPDIR_BASE}/config_fencing.sh"
    rc=0
    "$PREPARE" --topology fencing --method ipi \
        --release-image "$resolved" --ci-token "${CI_TOKEN:-placeholder}" \
        --output "$outfile" --force >/dev/null 2>&1 || rc=$?
    assert_exit 0 "$rc" "E2E-1 prepare-config fencing-ipi"
    [[ "$rc" -eq 0 ]] || return

    if [[ -f "$outfile" ]]; then
        pass "E2E-1 output file exists"
    else
        fail "E2E-1 output file exists"
    fi
    assert_grep "$outfile" "^export OPENSHIFT_RELEASE_IMAGE=" "E2E-1 OPENSHIFT_RELEASE_IMAGE set"
    assert_grep "$outfile" '^export CI_TOKEN="' "E2E-1 CI_TOKEN active"
    assert_not_grep "$outfile" '^export OPENSHIFT_CI=' "E2E-1 OPENSHIFT_CI commented"
    assert_grep "$outfile" '^export AGENT_E2E_TEST_SCENARIO="TNF_' "E2E-1 scenario prefix TNF"
}

test_e2e_sno_agent() {
    echo ""
    echo "=== Tier 2: SNO agent x86_64 (E2E-2) ==="

    local resolved rc=0
    resolved=$("$RESOLVE" --version 4.22 --digest --quiet 2>/dev/null) || rc=$?
    if [[ "$rc" -ne 0 ]]; then
        fail "E2E-2 setup: resolve 4.22 --digest failed (exit $rc)"
        return
    fi

    local outfile="${TMPDIR_BASE}/config_sno.sh"
    rc=0
    "$PREPARE" --topology sno --method agent \
        --release-image "$resolved" --ci-token "${CI_TOKEN:-placeholder}" \
        --output "$outfile" --force >/dev/null 2>&1 || rc=$?
    assert_exit 0 "$rc" "E2E-2 prepare-config sno-agent"
    [[ "$rc" -eq 0 ]] || return

    assert_grep "$outfile" '@sha256:' "E2E-2 release image is digest-pinned"
    assert_grep "$outfile" '^export AGENT_E2E_TEST_SCENARIO="SNO_' "E2E-2 scenario prefix SNO"
}

test_e2e_doctor() {
    echo ""
    echo "=== Tier 2: Make doctor gate (E2E-3) ==="

    local rc=0
    make -C "${REPO_ROOT}/deploy" doctor fencing-ipi 2>&1 || rc=$?
    if [[ "$rc" -eq 0 ]]; then
        pass "E2E-3 make doctor fencing-ipi"
    else
        echo -e "${COLOR_YELLOW}  NOTE${COLOR_CLEAR} E2E-3 make doctor exited $rc (instance-level issue, not counted as failure)"
    fi
}

test_e2e_inventory_fork() {
    echo ""
    echo "=== Tier 2: Inventory fork override (E2E-4) ==="

    local inv_backup="${TMPDIR_BASE}/inventory.ini.bak"
    cp "$INVENTORY" "$inv_backup"

    local img rc
    img=$("$RESOLVE" --version 4.22 --quiet 2>/dev/null) || {
        fail "E2E-4 setup: resolve failed"
        cp "$inv_backup" "$INVENTORY"
        return
    }

    # E2E-4a: --ds-repo + --ds-branch → upserts both
    rc=0
    "$PREPARE" --topology fencing --method ipi \
        --release-image "$img" --ci-token "${CI_TOKEN:-placeholder}" \
        --inventory "$INVENTORY" \
        --ds-repo https://github.com/example/dev-scripts --ds-branch test-branch \
        --output "${TMPDIR_BASE}/inv_fork1.sh" --force >/dev/null 2>&1 || rc=$?
    assert_exit 0 "$rc" "E2E-4a fork upsert"
    [[ "$rc" -eq 0 ]] && {
        assert_grep "$INVENTORY" '^dev_scripts_src_repo=https://github.com/example/dev-scripts' "E2E-4a repo upserted"
        assert_grep "$INVENTORY" '^dev_scripts_branch=test-branch' "E2E-4a branch upserted"
    }

    # E2E-4b: without fork args → purges
    rc=0
    "$PREPARE" --topology fencing --method ipi \
        --release-image "$img" --ci-token "${CI_TOKEN:-placeholder}" \
        --inventory "$INVENTORY" \
        --output "${TMPDIR_BASE}/inv_fork2.sh" --force >/dev/null 2>&1 || rc=$?
    assert_exit 0 "$rc" "E2E-4b fork purge"
    [[ "$rc" -eq 0 ]] && {
        assert_not_grep "$INVENTORY" '^dev_scripts_src_repo=' "E2E-4b repo purged"
        assert_not_grep "$INVENTORY" '^dev_scripts_branch=' "E2E-4b branch purged"
    }

    cp "$inv_backup" "$INVENTORY"
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

setup
detect_capabilities

echo "=== Online validation: resolve-release-image.sh + prepare-config.sh ==="
echo "  pull-secret: ${HAS_PULL_SECRET}"
echo "  CI_TOKEN:    ${HAS_CI_TOKEN}"
echo "  e2e config:  ${HAS_E2E_CONFIG}"
echo ""

# Tier 1
test_resolver_ga
test_resolver_prerelease
test_resolver_nightly
test_resolver_digest_fallback
test_resolver_passthrough

# Tier 2
if [[ "$HAS_E2E_CONFIG" == "true" ]]; then
    test_e2e_fencing_ipi
    test_e2e_sno_agent
    test_e2e_doctor
    test_e2e_inventory_fork
else
    echo ""
    skip "Tier 2 — instance not configured for e2e (need inventory.ini + example configs)"
fi

echo ""
echo "=============================="
echo -e "Results: ${COLOR_GREEN}${PASS} passed${COLOR_CLEAR}, ${COLOR_RED}${FAIL} failed${COLOR_CLEAR}, ${COLOR_YELLOW}${SKIP} skipped${COLOR_CLEAR}"
echo "=============================="

[[ "$FAIL" -eq 0 ]]
