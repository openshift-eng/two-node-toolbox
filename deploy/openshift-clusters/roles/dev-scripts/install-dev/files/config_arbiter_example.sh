#!/bin/bash


# Please copy one of the config values below for IPI or Agent based installs into your
# config.
# BEGIN IPI Specific Install Config Variables
export IP_STACK="v4"
export NUM_WORKERS=0
export ARBITER_MEMORY=16384
export ARBITER_VCPU=2
export NUM_ARBITERS=1
export MASTER_MEMORY=32768
export MASTER_DISK=100
export MASTER_VCPU=4
export NUM_MASTERS=2
## END IPI Specific Install Config Variables

## BEGIN Agent Specific Install Config Variables
export AGENT_E2E_TEST_SCENARIO="TNA_IPV4"
## END Agent Specific Install Config Variables
####

# TechPreview FeatureSet not needed for 4.20 and above OCP
# export FEATURE_SET="TechPreviewNoUpgrade"
export OPENSHIFT_CI="true"

# If you want to avoid using the CI_TOKEN, uncomment this variable, but it has side effects.
# You can read more on this here: https://github.com/openshift-metal3/dev-scripts/blob/3f070cfd36977381a186cadfb44887856d652bed/config_example.sh#L21
# export OPENSHIFT_CI="true"

# You can find the latest public images in https://quay.io/repository/openshift-release-dev/ocp-release?tab=tags 
# and select your preferred version. Public sources can be found at https://mirror.openshift.com/pub/openshift-v4/

export OPENSHIFT_RELEASE_IMAGE=quay.io/openshift-release-dev/ocp-release:4.20.0-ec.4-x86_64
# Unless you need to override the installer image, this is not needed
# export OPENSHIFT_INSTALL_RELEASE_IMAGE_OVERRIDE=""
