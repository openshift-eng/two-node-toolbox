#!/bin/bash

export IP_STACK="v4"
export NUM_WORKERS=0
export MASTER_MEMORY=32768
export MASTER_DISK=100
export NUM_MASTERS=2
# Ensure consistent BMC driver across all hosts for automatic fencing configuration
export BMC_DRIVER=redfish

# Controls the identifier used in fencing credentials for Two Node Fencing.
# Set to "hostname" to identify nodes by hostname (default), or "macAddress"
# to identify nodes by their boot MAC address.
#
#export FENCING_CREDENTIAL_IDENTIFIER=hostname

# If you want to avoid using the CI_TOKEN, uncomment this variable, but it has side effects.
# You can read more on this here: https://github.com/openshift-metal3/dev-scripts/blob/3f070cfd36977381a186cadfb44887856d652bed/config_example.sh#L21
# export OPENSHIFT_CI="true"
# If deploying fencing-agent, set the test scenario to TNF_IPV4
# export AGENT_E2E_TEST_SCENARIO="TNF_IPV4"

export CI_TOKEN="sha256~<PASTE_YOUR_CI_TOKEN_HERE>"

# You can find the latest public images in https://quay.io/repository/openshift-release-dev/ocp-release?tab=tags 
# and select your preferred version. Public sources can be found at https://mirror.openshift.com/pub/openshift-v4/

export OPENSHIFT_RELEASE_IMAGE=quay.io/openshift-release-dev/ocp-release:4.22.0-multi
# Unless you need to override the installer image, this is not needed
# export OPENSHIFT_INSTALL_RELEASE_IMAGE_OVERRIDE=""

# Disable sigstore image verification during installation
export OPENSHIFT_INSTALL_EXPERIMENTAL_DISABLE_IMAGE_POLICY=true

# aarch64 (Graviton) Metal3 image overrides — upstream images are x86_64-only.
# Rebuild monthly with: helpers/build-metal3-arm64.sh
# if [ "$(uname -m)" = "aarch64" ]; then
#     export IRONIC_IMAGE=quay.io/rh-edge-enablement/ironic:2026-06
#     export VBMC_IMAGE=quay.io/rh-edge-enablement/vbmc:2026-06
#     export SUSHY_TOOLS_IMAGE=quay.io/rh-edge-enablement/sushy-tools:2026-06
# fi

# Baremetal network config (node IPs, VIPs, bridge overrides) is auto-generated
# by 'make baremetal-adopt' into config_baremetal_fencing.sh — do not add here.
