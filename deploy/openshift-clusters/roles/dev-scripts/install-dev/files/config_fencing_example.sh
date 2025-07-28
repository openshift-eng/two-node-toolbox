#!/bin/bash

export IP_STACK="v4"
export NUM_WORKERS=0
export MASTER_MEMORY=32768
export MASTER_DISK=100
export NUM_MASTERS=2
export FEATURE_SET="DevPreviewNoUpgrade"

# redfish or ipmi, but if not set and using OPENSHIF_CI=true, 
# mixed drivers will be used and automatic fencing configuration in 4.19 won't work
export BMC_DRIVER=redfish 

# If you want to avoid using the CI_TOKEN, uncomment this variable, but it has side effects.
# You can read more on this here: https://github.com/openshift-metal3/dev-scripts/blob/3f070cfd36977381a186cadfb44887856d652bed/config_example.sh#L21
# export OPENSHIFT_CI="true"

export CI_TOKEN="sha256~<PASTE_YOUR_CI_TOKEN_HERE>"

# You can find the latest public images in https://quay.io/repository/openshift-release-dev/ocp-release?tab=tags 
# and select your preferred version. Public sources can be found at https://mirror.openshift.com/pub/openshift-v4/

export OPENSHIFT_RELEASE_IMAGE=quay.io/openshift-release-dev/ocp-release:4.19.5-multi
# Unless you need to override the installer image, this is not needed
# export OPENSHIFT_INSTALL_RELEASE_IMAGE_OVERRIDE=""




