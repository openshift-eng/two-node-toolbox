#!/usr/bin/env bash
#
# Interactive wizard for creating a baremetal node inventory.
#
# Collects BMC credentials and network info for each node, validates input,
# displays a summary for confirmation, and writes inventory_baremetal.ini.
#
# Usage:
#   baremetal-wizard.sh [options]
#
# Options:
#   --output FILE   Inventory output path (default: inventory_baremetal.ini)
#   -h, --help      Show this help message

set -o nounset
set -o errexit
set -o pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
OC_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

OUTPUT="${OC_DIR}/inventory_baremetal.ini"

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
            --output)
                [[ $# -lt 2 ]] && die "--output requires an argument"
                OUTPUT="$2"
                shift 2
                ;;
            -h|--help)
                head -14 "$0" | tail -9
                exit 0
                ;;
            *)
                die "Unknown option: $1. Run '$0 --help' for usage."
                ;;
        esac
    done
}

##############################################################################
# Validators
##############################################################################

valid_ipv4() {
    local ip="$1"
    local IFS='.'
    local -a octets
    read -ra octets <<< "${ip}"
    [[ ${#octets[@]} -ne 4 ]] && return 1
    local octet
    for octet in "${octets[@]}"; do
        [[ "${octet}" =~ ^[0-9]+$ ]] || return 1
        (( octet > 255 )) && return 1
    done
    return 0
}

valid_mac() {
    local mac="$1"
    [[ "${mac}" =~ ^([0-9a-fA-F]{2}:){5}[0-9a-fA-F]{2}$ ]]
}

valid_hostname() {
    local name="$1"
    [[ -n "${name}" ]] && [[ "${name}" =~ ^[a-zA-Z0-9]([a-zA-Z0-9._-]*[a-zA-Z0-9])?$ ]]
}

valid_bmc_address() {
    local addr="$1"
    valid_ipv4 "${addr}" || valid_hostname "${addr}"
}

valid_cidr() {
    local cidr="$1"
    local ip="${cidr%%/*}"
    local prefix="${cidr##*/}"
    [[ "${cidr}" == *"/"* ]] || return 1
    valid_ipv4 "${ip}" || return 1
    [[ "${prefix}" =~ ^[0-9]+$ ]] || return 1
    (( prefix <= 32 )) || return 1
    return 0
}

##############################################################################
# Prompt functions
#
# Each loops until valid input is received. Values go to stdout (for capture
# with val=$(...)), prompts and errors go to stderr (displayed on terminal).
##############################################################################

prompt_node_count() {
    local count
    while true; do
        read -rp "Number of baremetal nodes [2]: " count
        count="${count:-2}"
        if ! [[ "${count}" =~ ^[0-9]+$ ]]; then
            echo "  Error: must be a number" >&2
            continue
        fi
        if (( count < 2 )); then
            echo "  Error: TNF requires at least 2 nodes" >&2
            continue
        fi
        echo "${count}"
        return
    done
}

prompt_hostname() {
    local default_name="$1"
    local name
    while true; do
        read -rp "  Hostname [${default_name}]: " name
        name="${name:-${default_name}}"
        if ! valid_hostname "${name}"; then
            echo "  Error: invalid hostname (use alphanumeric, hyphens, dots)" >&2
            continue
        fi
        echo "${name}"
        return
    done
}

prompt_bmc_address() {
    local addr
    while true; do
        read -rp "  BMC address (IP or hostname): " addr
        if [[ -z "${addr}" ]]; then
            echo "  Error: BMC address is required" >&2
            continue
        fi
        if ! valid_bmc_address "${addr}"; then
            echo "  Error: invalid address (expected IPv4 or FQDN)" >&2
            continue
        fi
        echo "${addr}"
        return
    done
}

prompt_bmc_user() {
    local user
    read -rp "  BMC username [admin]: " user
    user="${user:-admin}"
    echo "${user}"
}

prompt_bmc_pass() {
    local pass
    while true; do
        read -rsp "  BMC password: " pass
        echo "" >&2
        if [[ -z "${pass}" ]]; then
            echo "  Error: BMC password is required" >&2
            continue
        fi
        echo "${pass}"
        return
    done
}

prompt_bmc_port() {
    local port
    while true; do
        read -rp "  BMC port [443]: " port
        port="${port:-443}"
        if ! [[ "${port}" =~ ^[0-9]+$ ]] || (( port < 1 || port > 65535 )); then
            echo "  Error: invalid port (expected 1-65535)" >&2
            continue
        fi
        echo "${port}"
        return
    done
}

prompt_boot_mac() {
    local mac
    while true; do
        read -rp "  Boot MAC address (Enter to auto-discover): " mac
        if [[ -z "${mac}" ]]; then
            echo "${mac}"
            return
        fi
        if ! valid_mac "${mac}"; then
            echo "  Error: invalid MAC (expected XX:XX:XX:XX:XX:XX)" >&2
            continue
        fi
        echo "${mac}"
        return
    done
}

prompt_data_mac() {
    local mac
    while true; do
        read -rp "  Data NIC MAC (data network interface): " mac
        if [[ -z "${mac}" ]]; then
            echo "  Error: data NIC MAC is required for baremetal deploy" >&2
            continue
        fi
        if ! valid_mac "${mac}"; then
            echo "  Error: invalid MAC (expected XX:XX:XX:XX:XX:XX)" >&2
            continue
        fi
        echo "${mac}"
        return
    done
}

prompt_node_ip() {
    local ip
    while true; do
        read -rp "  Node IP address: " ip
        if [[ -z "${ip}" ]]; then
            echo "  Error: node IP is required for baremetal deploy" >&2
            continue
        fi
        if ! valid_ipv4 "${ip}"; then
            echo "  Error: invalid IPv4 address" >&2
            continue
        fi
        echo "${ip}"
        return
    done
}

prompt_iso_url() {
    local url
    while true; do
        read -rp "  ISO URL for VirtualMedia boot (e.g. http://host:8080/path/agent.x86_64.iso): " url
        if [[ -z "${url}" ]]; then
            echo "  Error: ISO URL is required — BMCs mount the agent ISO via Redfish VirtualMedia" >&2
            continue
        fi
        if ! [[ "${url}" =~ ^https?:// ]]; then
            echo "  Error: expected http:// or https:// URL" >&2
            continue
        fi
        echo "${url}"
        return
    done
}

prompt_machine_network() {
    local cidr
    while true; do
        read -rp "  Machine network CIDR (e.g. 192.168.1.0/24, Enter to skip): " cidr
        if [[ -z "${cidr}" ]]; then
            echo "${cidr}"
            return
        fi
        if ! valid_cidr "${cidr}"; then
            echo "  Error: invalid CIDR (expected x.x.x.x/prefix)" >&2
            continue
        fi
        echo "${cidr}"
        return
    done
}

prompt_api_vip() {
    local vip
    while true; do
        read -rp "  API VIP: " vip
        if [[ -z "${vip}" ]]; then
            echo "  Error: API VIP is required for baremetal deploy" >&2
            continue
        fi
        if ! valid_ipv4 "${vip}"; then
            echo "  Error: invalid IPv4 address" >&2
            continue
        fi
        echo "${vip}"
        return
    done
}

prompt_ingress_vip() {
    local vip
    while true; do
        read -rp "  Ingress VIP (Enter to skip): " vip
        if [[ -z "${vip}" ]]; then
            echo "${vip}"
            return
        fi
        if ! valid_ipv4 "${vip}"; then
            echo "  Error: invalid IPv4 address" >&2
            continue
        fi
        echo "${vip}"
        return
    done
}

prompt_ssh_target() {
    local target
    while true; do
        read -rp "  SSH target for remote deployment (user@host, Enter to skip): " target
        if [[ -z "${target}" ]]; then
            echo "${target}"
            return
        fi
        if ! [[ "${target}" == *@* ]]; then
            echo "  Error: expected user@host format" >&2
            continue
        fi
        echo "${target}"
        return
    done
}

prompt_ssh_key() {
    local key
    read -rp "  SSH key path (Enter for ssh-agent/default): " key
    echo "${key}"
}

prompt_dev_scripts_path() {
    local path
    read -rp "  dev-scripts path on remote [~/openshift-metal3/dev-scripts]: " path
    echo "${path:-~/openshift-metal3/dev-scripts}"
}

prompt_working_dir() {
    local dir
    read -rp "  Remote working directory [~/tnt-baremetal]: " dir
    echo "${dir:-~/tnt-baremetal}"
}

##############################################################################
# Summary display
##############################################################################

show_summary() {
    echo ""
    echo "=================================="
    echo "  BAREMETAL NODE SUMMARY"
    echo "=================================="
    printf "  %-4s %-14s %-46s %-10s %-10s %-19s %-19s %-17s\n" \
        "#" "HOSTNAME" "BMC ADDRESS" "BMC USER" "PASSWORD" "BOOT MAC" "DATA MAC" "NODE IP"
    printf "  %-4s %-14s %-46s %-10s %-10s %-19s %-19s %-17s\n" \
        "---" "------------" "--------------------------------------------" "--------" "--------" "-----------------" "-----------------" "---------------"

    local i
    for ((i = 0; i < ${#WIZ_NAMES[@]}; i++)); do
        local display_mac="${WIZ_MACS[$i]:-auto-discover}"
        local display_data_mac="${WIZ_DATA_MACS[$i]:---}"
        local display_ip="${WIZ_NODE_IPS[$i]:---}"
        local display_addr="${WIZ_IPS[$i]}:${WIZ_PORTS[$i]}"
        printf "  %-4s %-14s %-46s %-10s %-10s %-19s %-19s %-17s\n" \
            "$((i + 1))" \
            "${WIZ_NAMES[$i]}" \
            "${display_addr}" \
            "${WIZ_USERS[$i]}" \
            "********" \
            "${display_mac}" \
            "${display_data_mac}" \
            "${display_ip}"
    done

    echo ""
    echo "  Cluster Network:"
    echo "    API VIP:         ${WIZ_API_VIP}"
    [[ -n "${WIZ_INGRESS_VIP}" ]] && echo "    Ingress VIP:     ${WIZ_INGRESS_VIP}"
    [[ -n "${WIZ_MACHINE_NETWORK}" ]] && echo "    Machine network: ${WIZ_MACHINE_NETWORK}"
    echo "    ISO URL:         ${WIZ_ISO_URL}"

    if [[ -n "${WIZ_SSH_TARGET}" ]]; then
        echo ""
        echo "  Provisioning Host:"
        echo "    SSH target:      ${WIZ_SSH_TARGET}"
        echo "    SSH key:         ${WIZ_SSH_KEY:---}"
        echo "    Dev-scripts:     ${WIZ_DEV_SCRIPTS_PATH:-~/openshift-metal3/dev-scripts}"
        echo "    Working dir:     ${WIZ_WORKING_DIR:-~/tnt-baremetal}"
    fi

    echo "=================================="
}

##############################################################################
# Wizard flow
##############################################################################

run_wizard() {
    info "Baremetal node inventory wizard"
    echo ""

    while true; do
        local node_count
        node_count=$(prompt_node_count)

        WIZ_NAMES=()
        WIZ_IPS=()
        WIZ_USERS=()
        WIZ_PASSES=()
        WIZ_PORTS=()
        WIZ_MACS=()
        WIZ_DATA_MACS=()
        WIZ_NODE_IPS=()

        local i
        for ((i = 0; i < node_count; i++)); do
            local default_name="master-${i}"
            echo ""
            echo "--- Node $((i + 1)) of ${node_count} ---"

            WIZ_NAMES+=("$(prompt_hostname "${default_name}")")
            WIZ_IPS+=("$(prompt_bmc_address)")
            WIZ_USERS+=("$(prompt_bmc_user)")
            WIZ_PASSES+=("$(prompt_bmc_pass)")
            WIZ_PORTS+=("$(prompt_bmc_port)")
            WIZ_MACS+=("$(prompt_boot_mac)")
            WIZ_DATA_MACS+=("$(prompt_data_mac)")
            WIZ_NODE_IPS+=("$(prompt_node_ip)")
        done

        echo ""
        echo "--- Cluster Network ---"
        WIZ_API_VIP="$(prompt_api_vip)"
        WIZ_INGRESS_VIP="$(prompt_ingress_vip)"
        WIZ_MACHINE_NETWORK="$(prompt_machine_network)"
        WIZ_ISO_URL="$(prompt_iso_url)"

        echo ""
        echo "--- Provisioning Host (optional) ---"
        WIZ_SSH_TARGET="$(prompt_ssh_target)"
        if [[ -n "${WIZ_SSH_TARGET}" ]]; then
            WIZ_SSH_KEY="$(prompt_ssh_key)"
            WIZ_DEV_SCRIPTS_PATH="$(prompt_dev_scripts_path)"
            WIZ_WORKING_DIR="$(prompt_working_dir)"
        else
            WIZ_SSH_KEY=""
            WIZ_DEV_SCRIPTS_PATH=""
            WIZ_WORKING_DIR=""
        fi

        show_summary

        while true; do
            local confirm
            read -rp "Proceed with this configuration? [Y/n/q]: " confirm
            confirm="${confirm:-Y}"

            case "${confirm}" in
                [Yy]|[Yy]es)
                    break 2
                    ;;
                [Nn]|[Nn]o)
                    echo ""
                    info "Starting over — re-enter node information"
                    echo ""
                    break
                    ;;
                [Qq]|[Qq]uit)
                    die "Wizard cancelled by user"
                    ;;
                *)
                    echo "  Please enter Y, n, or q" >&2
                    ;;
            esac
        done
    done

    write_inventory
}

##############################################################################
# Inventory writer
##############################################################################

write_inventory() {
    local tmp_inventory
    tmp_inventory=$(mktemp)

    {
        echo "# Generated by baremetal-wizard.sh"
        echo ""
        echo "[baremetal_nodes]"
    } > "${tmp_inventory}"

    local i
    for ((i = 0; i < ${#WIZ_NAMES[@]}; i++)); do
        local line="${WIZ_NAMES[$i]} bmc_address=${WIZ_IPS[$i]} bmc_user=${WIZ_USERS[$i]} bmc_pass=${WIZ_PASSES[$i]} bmc_port=${WIZ_PORTS[$i]}"
        if [[ -n "${WIZ_MACS[$i]}" ]]; then
            line+=" boot_mac=${WIZ_MACS[$i]}"
        fi
        line+=" data_mac=${WIZ_DATA_MACS[$i]}"
        line+=" node_ip=${WIZ_NODE_IPS[$i]}"
        echo "${line}" >> "${tmp_inventory}"
    done

    {
        echo ""
        echo "[baremetal_nodes:vars]"
        echo "bmc_driver=redfish"
        echo "bmc_port=443"
        echo "bmc_verify_ca=False"
        echo "cpu_arch=x86_64"

        echo ""
        echo "[baremetal_network]"
        echo "api_vip=${WIZ_API_VIP}"
        if [[ -n "${WIZ_INGRESS_VIP}" ]]; then
            echo "ingress_vip=${WIZ_INGRESS_VIP}"
        else
            echo "#ingress_vip="
        fi
        if [[ -n "${WIZ_MACHINE_NETWORK}" ]]; then
            echo "machine_network=${WIZ_MACHINE_NETWORK}"
        else
            echo "#machine_network="
        fi
        echo "iso_url=${WIZ_ISO_URL}"

        echo ""
        echo "[provisioning_host]"
        if [[ -n "${WIZ_SSH_TARGET}" ]]; then
            local prov_user="${WIZ_SSH_TARGET%%@*}"
            local prov_host="${WIZ_SSH_TARGET#*@}"
            local host_line="${prov_host} ansible_user=${prov_user}"
            if [[ -n "${WIZ_SSH_KEY}" ]]; then
                host_line+=" ansible_ssh_private_key_file=${WIZ_SSH_KEY}"
            fi
            echo "${host_line}"
        else
            echo "#host ansible_user=root"
        fi

        echo ""
        echo "[provisioning_host:vars]"
        if [[ -n "${WIZ_DEV_SCRIPTS_PATH}" ]]; then
            echo "dev_scripts_path=${WIZ_DEV_SCRIPTS_PATH}"
        else
            echo "#dev_scripts_path="
        fi
        if [[ -n "${WIZ_WORKING_DIR}" ]]; then
            echo "working_dir=${WIZ_WORKING_DIR}"
        else
            echo "#working_dir="
        fi
    } >> "${tmp_inventory}"

    mv "${tmp_inventory}" "${OUTPUT}"
    echo ""
    info "Inventory written to ${OUTPUT}"
}

##############################################################################
# Main
##############################################################################

declare -a WIZ_NAMES=()
declare -a WIZ_IPS=()
declare -a WIZ_USERS=()
declare -a WIZ_PASSES=()
declare -a WIZ_PORTS=()
declare -a WIZ_MACS=()
declare -a WIZ_DATA_MACS=()
declare -a WIZ_NODE_IPS=()
WIZ_MACHINE_NETWORK=""
WIZ_API_VIP=""
WIZ_INGRESS_VIP=""
WIZ_ISO_URL=""
WIZ_SSH_TARGET=""
WIZ_SSH_KEY=""
WIZ_DEV_SCRIPTS_PATH=""
WIZ_WORKING_DIR=""

parse_args "$@"
run_wizard
