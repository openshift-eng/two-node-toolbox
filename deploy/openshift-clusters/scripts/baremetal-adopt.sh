#!/usr/bin/env bash
#
# Adopt existing baremetal nodes for TNF deployment.
#
# Parses inventory_baremetal.ini, validates BMC credentials via Redfish,
# and generates ironic_nodes.json + config_baremetal_fencing.sh for dev-scripts.
#
# Usage:
#   baremetal-adopt.sh [options]
#
# Options:
#   --skip-verify         Skip all BMC access (verify + discovery); requires boot_mac in inventory
#   --verify-only         Only verify BMC credentials, don't generate artifacts
#   --inventory FILE       Path to baremetal inventory (default: inventory_baremetal.ini)
#   --config-base FILE    Base config to derive baremetal config from
#   -h, --help            Show this help message

set -o nounset
set -o errexit
set -o pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
OC_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

SKIP_VERIFY=false
VERIFY_ONLY=false
CONFIG_BASE=""
INVENTORY="${OC_DIR}/inventory_baremetal.ini"

# Node data arrays — populated by parse_inventory
declare -a NODE_NAMES=()
declare -a NODE_BMC_ADDRS=()
declare -a NODE_BMC_USERS=()
declare -a NODE_BMC_PASSES=()
declare -a NODE_BMC_PORTS=()
declare -a NODE_BOOT_MACS=()
declare -a NODE_DATA_MACS=()
declare -a NODE_IPS=()

# Cluster-wide network config (from [baremetal_network])
MACHINE_NETWORK=""
API_VIP=""
INGRESS_VIP=""
ISO_URL=""

# Group defaults
BMC_PORT="443"
BMC_VERIFY_CA="False"
CPU_ARCH="x86_64"

##############################################################################
# Helpers
##############################################################################

die() { echo "Error: $*" >&2; exit 1; }

info() { echo "==> $*"; }

##############################################################################
# Argument parsing
##############################################################################

parse_args() {
    while [[ $# -gt 0 ]]; do
        case $1 in
            --skip-verify)
                SKIP_VERIFY=true
                shift
                ;;
            --verify-only)
                VERIFY_ONLY=true
                shift
                ;;
            --inventory)
                [[ $# -lt 2 ]] && die "--inventory requires an argument"
                INVENTORY="$2"
                shift 2
                ;;
            --config-base)
                [[ $# -lt 2 ]] && die "--config-base requires an argument"
                CONFIG_BASE="$2"
                shift 2
                ;;
            -h|--help)
                head -16 "$0" | tail -11
                exit 0
                ;;
            *)
                die "Unknown option: $1. Run '$0 --help' for usage."
                ;;
        esac
    done
}

##############################################################################
# INI parser
##############################################################################

parse_inventory() {
    [[ -f "${INVENTORY}" ]] || die "Inventory file not found: ${INVENTORY}"

    local in_nodes=false
    local in_vars=false
    local in_network=false

    while IFS= read -r line || [[ -n "${line}" ]]; do
        # Strip comments and leading/trailing whitespace
        line="${line%%#*}"
        line="${line#"${line%%[![:space:]]*}"}"
        line="${line%"${line##*[![:space:]]}"}"
        [[ -z "${line}" ]] && continue

        if [[ "${line}" == "[baremetal_nodes]" ]]; then
            in_nodes=true
            in_vars=false
            continue
        elif [[ "${line}" == "[baremetal_nodes:vars]" ]]; then
            in_nodes=false
            in_vars=true
            continue
        elif [[ "${line}" == "[baremetal_network]" ]]; then
            in_nodes=false
            in_vars=false
            in_network=true
            continue
        elif [[ "${line}" =~ ^\[.*\] ]]; then
            in_nodes=false
            in_vars=false
            in_network=false
            continue
        fi

        if ${in_vars}; then
            local key val
            key="${line%%=*}"
            val="${line#*=}"
            case "${key}" in
                bmc_port)      BMC_PORT="${val}" ;;
                bmc_verify_ca) BMC_VERIFY_CA="${val}" ;;
                cpu_arch)      CPU_ARCH="${val}" ;;
            esac
            continue
        fi

        if ${in_network}; then
            local key val
            key="${line%%=*}"
            val="${line#*=}"
            case "${key}" in
                machine_network) MACHINE_NETWORK="${val}" ;;
                api_vip)         API_VIP="${val}" ;;
                ingress_vip)     INGRESS_VIP="${val}" ;;
                iso_url)         ISO_URL="${val}" ;;
            esac
            continue
        fi

        if ${in_nodes}; then
            local name rest
            name="${line%% *}"
            rest="${line#* }"

            local bmc_address="" bmc_user="" bmc_pass="" bmc_port="" boot_mac="" node_ip="" data_mac=""
            for pair in ${rest}; do
                local key val
                key="${pair%%=*}"
                val="${pair#*=}"
                case "${key}" in
                    bmc_address) bmc_address="${val}" ;;
                    bmc_user)    bmc_user="${val}" ;;
                    bmc_pass)    bmc_pass="${val}" ;;
                    bmc_port)    bmc_port="${val}" ;;
                    boot_mac)    boot_mac="${val}" ;;
                    node_ip)     node_ip="${val}" ;;
                    data_mac)    data_mac="${val}" ;;
                esac
            done

            [[ -z "${bmc_address}" ]] && die "Node '${name}': missing bmc_address"
            [[ -z "${bmc_user}" ]] && die "Node '${name}': missing bmc_user"
            [[ -z "${bmc_pass}" ]] && die "Node '${name}': missing bmc_pass"

            NODE_NAMES+=("${name}")
            NODE_BMC_ADDRS+=("${bmc_address}")
            NODE_BMC_USERS+=("${bmc_user}")
            NODE_BMC_PASSES+=("${bmc_pass}")
            NODE_BMC_PORTS+=("${bmc_port:-${BMC_PORT}}")
            NODE_BOOT_MACS+=("${boot_mac}")
            NODE_DATA_MACS+=("${data_mac}")
            NODE_IPS+=("${node_ip}")
        fi
    done < "${INVENTORY}"

    [[ ${#NODE_NAMES[@]} -eq 0 ]] && die "No nodes found in inventory"
    if [[ ${#NODE_NAMES[@]} -ne 2 ]]; then
        echo "  WARNING: TNF requires exactly 2 nodes, found ${#NODE_NAMES[@]}" >&2
    fi
    info "Parsed ${#NODE_NAMES[@]} node(s) from inventory"
}

##############################################################################
# BMC verification via Redfish
##############################################################################

bmc_curl() {
    local opts=(-s --connect-timeout 5 --max-time 10)
    [[ "${BMC_VERIFY_CA}" == "False" ]] && opts+=(-k)
    curl "${opts[@]}" "$@"
}

discover_redfish_system_id() {
    local bmc_address="$1" bmc_user="$2" bmc_pass="$3" bmc_port="$4"

    local systems_json
    systems_json=$(bmc_curl \
        -u "${bmc_user}:${bmc_pass}" \
        "https://${bmc_address}:${bmc_port}/redfish/v1/Systems/" 2>/dev/null) || return 1

    echo "${systems_json}" | jq -r '.Members[0]."@odata.id" // empty' 2>/dev/null
}

discover_boot_mac() {
    local bmc_address="$1" bmc_user="$2" bmc_pass="$3" bmc_port="$4" system_id="$5"

    # Get boot order from the system resource
    local boot_order
    boot_order=$(bmc_curl \
        -u "${bmc_user}:${bmc_pass}" \
        "https://${bmc_address}:${bmc_port}/${system_id}" 2>/dev/null \
        | jq -r '.Boot.BootOrder[]' 2>/dev/null) || return 1

    # Fetch all boot options and index by BootOptionReference
    local options_json
    options_json=$(bmc_curl \
        -u "${bmc_user}:${bmc_pass}" \
        "https://${bmc_address}:${bmc_port}/${system_id}/BootOptions/" 2>/dev/null) || return 1

    local option_paths
    option_paths=$(echo "${options_json}" | jq -r '.Members[]."@odata.id"' 2>/dev/null) || return 1

    # Build associative arrays: ref → display_name, ref → uefi_path
    declare -A opt_display opt_path
    for option_url in ${option_paths}; do
        local option
        option=$(bmc_curl \
            -u "${bmc_user}:${bmc_pass}" \
            "https://${bmc_address}:${bmc_port}${option_url}" 2>/dev/null) || continue

        local ref
        ref=$(echo "${option}" | jq -r '.BootOptionReference // empty' 2>/dev/null)
        [[ -z "${ref}" ]] && continue
        opt_display["${ref}"]=$(echo "${option}" | jq -r '.DisplayName // empty' 2>/dev/null)
        opt_path["${ref}"]=$(echo "${option}" | jq -r '.UefiDevicePath // empty' 2>/dev/null)
    done

    # Walk boot order, find the first PXE IPv4 entry
    for boot_ref in ${boot_order}; do
        local display_name="${opt_display[${boot_ref}]:-}"
        local uefi_path="${opt_path[${boot_ref}]:-}"

        if [[ "${display_name}" == *"PXE IPv4"* ]] && [[ "${uefi_path}" == *MAC* ]]; then
            local raw_mac
            raw_mac=$(echo "${uefi_path}" | grep -oP 'MAC\(\K[0-9A-Fa-f]+' 2>/dev/null) || continue
            echo "${raw_mac}" | sed 's/\(..\)/\1:/g; s/:$//' | tr '[:lower:]' '[:upper:]'
            return 0
        fi
    done
    return 1
}

verify_bmc() {
    local name="$1" bmc_address="$2" bmc_user="$3" bmc_pass="$4" bmc_port="$5"
    local rc=0

    printf "  %-12s %-20s " "${name}" "${bmc_address}:${bmc_port}"

    # Verify Redfish root is reachable and credentials work
    local http_code
    http_code=$(bmc_curl \
        -o /dev/null -w '%{http_code}' \
        -u "${bmc_user}:${bmc_pass}" \
        "https://${bmc_address}:${bmc_port}/redfish/v1/" 2>/dev/null) || http_code="000"

    if [[ "${http_code}" == "200" ]]; then
        echo "OK (HTTP ${http_code})"
    elif [[ "${http_code}" == "401" ]]; then
        echo "FAIL — bad credentials (HTTP 401)"
        rc=1
    elif [[ "${http_code}" == "000" ]]; then
        echo "FAIL — unreachable"
        rc=1
    else
        echo "FAIL (HTTP ${http_code})"
        rc=1
    fi

    return ${rc}
}

verify_all_bmcs() {
    info "Verifying BMC credentials via Redfish"
    echo ""

    local failed=0
    for ((i = 0; i < ${#NODE_NAMES[@]}; i++)); do
        if ! verify_bmc "${NODE_NAMES[$i]}" "${NODE_BMC_ADDRS[$i]}" \
                "${NODE_BMC_USERS[$i]}" "${NODE_BMC_PASSES[$i]}" "${NODE_BMC_PORTS[$i]}"; then
            failed=$((failed + 1))
        fi
    done
    echo ""

    if [[ ${failed} -gt 0 ]]; then
        die "${failed} node(s) failed BMC verification"
    fi
    info "All BMC endpoints verified"
}

##############################################################################
# Artifact generation
##############################################################################

generate_ironic_nodes_json() {
    local output_file="$1"

    info "Generating ironic_nodes.json"

    local incomplete=false
    local nodes=()

    for ((i = 0; i < ${#NODE_NAMES[@]}; i++)); do
        local name="${NODE_NAMES[$i]}"
        local bmc_address="${NODE_BMC_ADDRS[$i]}"
        local bmc_user="${NODE_BMC_USERS[$i]}"
        local bmc_pass="${NODE_BMC_PASSES[$i]}"
        local bmc_port="${NODE_BMC_PORTS[$i]}"
        local boot_mac="${NODE_BOOT_MACS[$i]}"

        # Discover Redfish system path (requires BMC access)
        local system_id
        if ${SKIP_VERIFY}; then
            system_id="redfish/v1/Systems/1"
        else
            system_id=$(discover_redfish_system_id "${bmc_address}" "${bmc_user}" "${bmc_pass}" "${bmc_port}" 2>/dev/null) || true
            if [[ -z "${system_id}" ]]; then
                echo "  WARNING: ${name}: Redfish system discovery failed, using default /redfish/v1/Systems/1" >&2
                system_id="/redfish/v1/Systems/1"
            fi
            system_id="${system_id#/}"
            system_id="${system_id%/}"
        fi

        # Auto-discover boot MAC via Redfish if not provided
        if [[ -z "${boot_mac}" ]]; then
            if ${SKIP_VERIFY}; then
                echo "  ERROR: ${name}: boot_mac required when using --skip-verify" >&2
                incomplete=true
                continue
            fi
            info "  ${name}: boot_mac not set, attempting Redfish discovery..."
            boot_mac=$(discover_boot_mac "${bmc_address}" "${bmc_user}" "${bmc_pass}" "${bmc_port}" "${system_id}" 2>/dev/null) || true
            if [[ -n "${boot_mac}" ]]; then
                info "  ${name}: discovered boot MAC ${boot_mac}"
            else
                echo "  ERROR: ${name}: could not discover boot MAC — set boot_mac in inventory" >&2
                incomplete=true
                continue
            fi
        fi

        nodes+=("$(jq -n \
            --arg name "${name}" \
            --arg addr "redfish://${bmc_address}:${bmc_port}/${system_id}" \
            --arg user "${bmc_user}" \
            --arg pass "${bmc_pass}" \
            --arg verify_ca "${BMC_VERIFY_CA}" \
            --arg mac "${boot_mac}" \
            --arg arch "${CPU_ARCH}" \
            '{
                name: $name,
                driver: "redfish",
                driver_info: {
                    address: $addr,
                    username: $user,
                    password: $pass,
                    redfish_verify_ca: $verify_ca
                },
                ports: [{address: $mac}],
                properties: {cpu_arch: $arch}
            }')")
    done

    if ${incomplete}; then
        die "Incomplete artifacts — set missing boot_mac values in inventory"
    fi

    printf '%s\n' "${nodes[@]}" | jq -s '{nodes: .}' > "${output_file}"
    info "  → ${output_file}"
}

generate_baremetal_config() {
    local output_file="$1"
    local nodes_file_path="$2"

    info "Generating config_baremetal_fencing.sh"

    # Find the base config to derive from
    local base_config="${CONFIG_BASE}"
    if [[ -z "${base_config}" ]]; then
        local files_dir="${OC_DIR}/roles/dev-scripts/install-dev/files"
        if [[ -f "${files_dir}/config_fencing.sh" ]]; then
            base_config="${files_dir}/config_fencing.sh"
        elif [[ -f "${files_dir}/config_fencing_example.sh" ]]; then
            base_config="${files_dir}/config_fencing_example.sh"
        else
            die "No base config found. Provide one with --config-base."
        fi
    fi

    [[ -f "${base_config}" ]] || die "Base config not found: ${base_config}"
    info "  Base config: ${base_config}"

    {
        cat "${base_config}"
        echo ""
        echo "# Baremetal adoption overrides (generated by baremetal-adopt.sh)"
        echo "export NODES_PLATFORM=baremetal"
        echo "export NODES_FILE=\"${nodes_file_path}\""
        echo "export MANAGE_BR_BRIDGE=n"
        echo "export MANAGE_PRO_BRIDGE=n"
        echo "export MANAGE_INT_BRIDGE=n"
        echo "export AGENT_E2E_TEST_SCENARIO=\"TNF_IPV4_DHCP\""

        # AGENT_BAREMETAL_IPS is required — dev-scripts agent pipeline needs node IPs
        local ip_list=""
        for ((i = 0; i < ${#NODE_IPS[@]}; i++)); do
            [[ -z "${NODE_IPS[$i]}" ]] && die "Node '${NODE_NAMES[$i]}': node_ip is required for baremetal deploy"
            [[ -n "${ip_list}" ]] && ip_list+=","
            ip_list+="${NODE_IPS[$i]}"
        done
        echo "export AGENT_BAREMETAL_IPS=\"${ip_list}\""

        # BAREMETAL_API_VIP is platform-level (used by both IPI and ABI in network.sh)
        [[ -z "${API_VIP}" ]] && die "api_vip is required in [baremetal_network] for baremetal deploy"
        [[ -z "${ISO_URL}" ]] && die "iso_url is required in [baremetal_network] for baremetal deploy"
        echo ""
        echo "# Baremetal network config"
        echo "export BAREMETAL_API_VIP=\"${API_VIP}\""
        echo "export AGENT_BAREMETAL_ISO_SERVER=\"${ISO_URL}\""
        [[ -n "${MACHINE_NETWORK}" ]] && echo "export EXTERNAL_SUBNET_V4=\"${MACHINE_NETWORK}\""
        [[ -n "${INGRESS_VIP}" ]] && echo "export BAREMETAL_INGRESS_VIP=\"${INGRESS_VIP}\""

        # AGENT_BAREMETAL_MACS is required — agent-config needs data NIC MACs for hostname mapping
        local mac_list=""
        for ((i = 0; i < ${#NODE_DATA_MACS[@]}; i++)); do
            [[ -z "${NODE_DATA_MACS[$i]}" ]] && die "Node '${NODE_NAMES[$i]}': data_mac is required for baremetal deploy"
            [[ -n "${mac_list}" ]] && mac_list+=","
            mac_list+="${NODE_DATA_MACS[$i]}"
        done
        echo "export AGENT_BAREMETAL_MACS=\"${mac_list}\""
    } > "${output_file}"

    info "  → ${output_file}"
}

##############################################################################
# Main
##############################################################################

main() {
    parse_args "$@"

    if ${SKIP_VERIFY} && ${VERIFY_ONLY}; then
        die "--skip-verify and --verify-only are mutually exclusive"
    fi

    # Launch interactive wizard if no inventory exists
    if [[ ! -f "${INVENTORY}" ]]; then
        info "No inventory found at ${INVENTORY}"
        info "Launching interactive wizard (or provide --inventory PATH)"
        "${SCRIPT_DIR}/baremetal-wizard.sh" --output "${INVENTORY}"
    fi

    parse_inventory

    # Validate required fields before expensive BMC calls
    for ((i = 0; i < ${#NODE_NAMES[@]}; i++)); do
        [[ -z "${NODE_DATA_MACS[$i]}" ]] && die "Node '${NODE_NAMES[$i]}': data_mac is required"
        [[ -z "${NODE_IPS[$i]}" ]] && die "Node '${NODE_NAMES[$i]}': node_ip is required"
    done

    # BMC verification
    if ! ${SKIP_VERIFY}; then
        verify_all_bmcs
    fi

    if ${VERIFY_ONLY}; then
        info "Verification complete (--verify-only). No artifacts generated."
        exit 0
    fi

    local repo_root
    repo_root="$(cd "${OC_DIR}/../.." && pwd)"
    local config_dir="${repo_root}/config"
    local files_dir="${OC_DIR}/roles/dev-scripts/install-dev/files"

    # Generate ironic nodes alongside existing dev-scripts files
    local nodes_file="${files_dir}/ironic_nodes.json"
    generate_ironic_nodes_json "${nodes_file}"

    # Generate config into config/ — sync-config carries it to the canonical location
    local remote_nodes_path="\${PWD}/ironic_nodes.json"
    if [[ -f "${config_dir}/config_baremetal_fencing.sh" ]]; then
        local backup
        backup="${config_dir}/config_baremetal_fencing.sh.bak.$(date +%s)"
        cp "${config_dir}/config_baremetal_fencing.sh" "${backup}"
        info "Existing config_baremetal_fencing.sh backed up to ${backup}"
    fi
    generate_baremetal_config "${config_dir}/config_baremetal_fencing.sh" "${remote_nodes_path}"

    echo ""
    info "Adoption complete. Generated artifacts:"
    echo "    ${nodes_file}"
    echo "    ${config_dir}/config_baremetal_fencing.sh"
    echo ""
    echo "  Before deploying, verify these values in ${config_dir}/config_baremetal_fencing.sh:"
    echo "    - CI_TOKEN        (get from console-openshift-console.apps.ci.l2s4.p1.openshiftapps.com)"
    echo "    - OPENSHIFT_RELEASE_IMAGE  (find tags at quay.io/openshift-release-dev/ocp-release)"
    echo ""
    echo "  The config will be synced to its canonical location automatically by 'make sync-config'."
    echo ""
    echo "  Next: deploy to the nodes using one of the baremetal-deploy* options"
}

main "$@"
