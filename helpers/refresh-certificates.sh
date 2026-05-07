#!/bin/bash
#
# refresh-certificates.sh - Refresh expiring OpenShift API server signer certificates
#
# This script checks each kube-apiserver signer certificate's remaining validity.
# Only signers expiring within a threshold (default: 7 days) are deleted and regenerated.
# Long-lived signers (e.g. 10-year) are left untouched to avoid invalidating the kubeconfig's embedded CA.
#
# Usage:
#   ./refresh-certificates.sh [--proxy-env /path/to/proxy.env] [--threshold HOURS]
#
# If --proxy-env is not specified, the script will look for proxy.env in
# the standard location relative to the two-node-toolbox deploy directory.
#

set -o nounset
set -o pipefail

# Get the directory where this script is located
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Default proxy.env location (relative to helpers/)
DEFAULT_PROXY_ENV="${SCRIPT_DIR}/../deploy/openshift-clusters/proxy.env"

# Signers expiring within this threshold (in hours) will be refreshed
DEFAULT_THRESHOLD_HOURS=168

# Parse arguments
PROXY_ENV=""
THRESHOLD_HOURS="${DEFAULT_THRESHOLD_HOURS}"
while [[ $# -gt 0 ]]; do
    case $1 in
        --proxy-env)
            PROXY_ENV="$2"
            shift 2
            ;;
        --threshold)
            if [[ $# -lt 2 || "$2" == -* ]]; then
                echo "Error: --threshold requires a numeric argument"
                exit 1
            fi
            if ! [[ "$2" =~ ^[0-9]+$ ]]; then
                echo "Error: --threshold value must be a positive integer, got '$2'"
                exit 1
            fi
            THRESHOLD_HOURS="$2"
            shift 2
            ;;
        -h|--help)
            echo "Usage: $0 [--proxy-env /path/to/proxy.env] [--threshold HOURS]"
            echo ""
            echo "Refresh expiring OpenShift API server signer certificates."
            echo "Only signers expiring within the threshold are refreshed."
            echo ""
            echo "Options:"
            echo "  --proxy-env PATH   Path to proxy.env file (default: deploy/openshift-clusters/proxy.env)"
            echo "  --threshold HOURS  Refresh signers expiring within this many hours (default: ${DEFAULT_THRESHOLD_HOURS})"
            echo "  -h, --help         Show this help message"
            exit 0
            ;;
        *)
            echo "Unknown option: $1"
            echo "Use --help for usage information"
            exit 1
            ;;
    esac
done

# Use default if not specified
if [[ -z "${PROXY_ENV}" ]]; then
    PROXY_ENV="${DEFAULT_PROXY_ENV}"
fi

THRESHOLD_SECONDS=$((THRESHOLD_HOURS * 3600))

echo "========================================"
echo "OpenShift Certificate Refresh"
echo "========================================"
echo ""

# Check if proxy.env exists
if [[ ! -f "${PROXY_ENV}" ]]; then
    echo "Error: proxy.env not found at ${PROXY_ENV}"
    echo ""
    echo "Please specify the correct path with --proxy-env or ensure"
    echo "the cluster has been deployed and proxy.env exists."
    exit 1
fi

echo "Loading proxy environment from: ${PROXY_ENV}"
# shellcheck source=/dev/null
source "${PROXY_ENV}"

# Verify we can reach the API
echo "Checking cluster API accessibility..."
if ! oc get nodes --request-timeout=10s &>/dev/null; then
    echo ""
    echo "Error: Cannot reach the cluster API."
    echo ""
    echo "Possible causes:"
    echo "  - Cluster is not running"
    echo "  - Proxy is not accessible"
    echo "  - Certificates have already expired"
    echo ""
    echo "If the cluster is running, check that the proxy (squid) is accessible"
    echo "at ${HTTP_PROXY:-<not set>}"
    exit 1
fi

echo "Cluster API is accessible."
echo ""

SIGNERS=(
    "aggregator-client-signer"
    "loadbalancer-serving-signer"
    "localhost-serving-signer"
    "service-network-serving-signer"
)

echo "Checking signer certificate expiry (refresh threshold: ${THRESHOLD_HOURS}h)..."
echo ""

NOW_EPOCH=$(date +%s)
SIGNERS_TO_REFRESH=()

for signer in "${SIGNERS[@]}"; do
    EXPIRY=$(oc get secret "${signer}" -n openshift-kube-apiserver-operator \
        -o jsonpath='{.metadata.annotations.auth\.openshift\.io/certificate-not-after}' 2>/dev/null || echo "")

    if [[ -z "${EXPIRY}" ]]; then
        echo "  ${signer}: expiry not found, skipping"
        continue
    fi

    EXPIRY_EPOCH=$(date -d "${EXPIRY}" +%s 2>/dev/null || echo "0")
    if [[ "${EXPIRY_EPOCH}" == "0" ]]; then
        echo "  ${signer}: could not parse expiry '${EXPIRY}', skipping"
        continue
    fi

    REMAINING=$((EXPIRY_EPOCH - NOW_EPOCH))
    REMAINING_HOURS=$((REMAINING / 3600))

    if [[ ${REMAINING} -le ${THRESHOLD_SECONDS} ]]; then
        echo "  ${signer}: expires ${EXPIRY} (${REMAINING_HOURS}h remaining) -> Will refresh"
        SIGNERS_TO_REFRESH+=("${signer}")
    else
        echo "  ${signer}: expires ${EXPIRY} (${REMAINING_HOURS}h remaining) -> Skipping"
    fi
done

echo ""

if [[ ${#SIGNERS_TO_REFRESH[@]} -eq 0 ]]; then
    echo "All signer certificates have sufficient remaining validity."
    echo "No refresh needed."
    exit 0
fi

echo "Refreshing ${#SIGNERS_TO_REFRESH[@]} signer(s)..."
for signer in "${SIGNERS_TO_REFRESH[@]}"; do
    echo "  Deleting ${signer}..."
    oc delete secret "${signer}" -n openshift-kube-apiserver-operator --ignore-not-found=true
done

echo ""
echo "Waiting for certificate regeneration (up to 60s)..."

TIMEOUT=60
ELAPSED=0
ALL_EXIST=false
while [[ ${ELAPSED} -lt ${TIMEOUT} ]]; do
    ALL_EXIST=true
    for signer in "${SIGNERS_TO_REFRESH[@]}"; do
        if ! oc get secret "${signer}" -n openshift-kube-apiserver-operator &>/dev/null; then
            ALL_EXIST=false
            break
        fi
    done
    if [[ "${ALL_EXIST}" == "true" ]]; then
        break
    fi
    sleep 5
    ELAPSED=$((ELAPSED + 5))
    echo -n "."
done
echo ""
echo ""

echo "Updated certificate expiry times:"
for signer in "${SIGNERS_TO_REFRESH[@]}"; do
    EXPIRY=$(oc get secret "${signer}" -n openshift-kube-apiserver-operator \
        -o jsonpath='{.metadata.annotations.auth\.openshift\.io/certificate-not-after}' 2>/dev/null || echo "not found")
    echo "  ${signer}: ${EXPIRY}"
done
echo ""

if [[ "${ALL_EXIST}" == "true" ]]; then
    echo "Certificate refresh completed successfully!"
else
    echo "Warning: Some certificates may still be regenerating."
    echo "Check kube-apiserver-operator logs if issues persist."
    exit 1
fi
