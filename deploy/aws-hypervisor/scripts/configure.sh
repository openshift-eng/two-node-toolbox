#!/bin/bash
# shellcheck source=/dev/null
source ~/profile.env

sudo hostnamectl set-hostname "aws-${STACK_NAME}"

function get_ocp_version() {
    local latest_ga_ocp_version
    local default_version="${DEFAULT_OCP_VERSION:-4.20}"
    if latest_ga_ocp_version="$(curl -sL https://sippy.dptools.openshift.org/api/releases | jq -re '.ga_dates | to_entries | max_by(.value) | .key')";
    then
        echo "${latest_ga_ocp_version:-$default_version}"
    else
        echo "$default_version"
    fi
}

user=${1:-pitadmin}
if id "$user" >/dev/null 2>&1; then
    echo "user $user found"
else
    echo "user $user not found, creating"
    sudo useradd -m "$user"
    # Generate a random secure password
    random_password=$(openssl rand -base64 12)
    echo "${random_password}" | sudo passwd --stdin "$user"
    echo "========================================"
    echo "User: $user"
    echo "Password: $random_password"
    echo "========================================"
    echo -e "${user}\tALL=(ALL)\tNOPASSWD: ALL" | sudo tee "/etc/sudoers.d/${user}"
fi

sudo rm -rf /etc/yum.repos.d/*
sudo subscription-manager config --rhsm.manage_repos=1 --rhsmcertd.disable=redhat-access-insights

# Use activation key for non-interactive registration if available
if [ -n "${RHSM_ACTIVATION_KEY}" ] && [ -n "${RHSM_ORG}" ]; then
    echo "Using activation key for RHSM registration"
    sudo subscription-manager register --activationkey="${RHSM_ACTIVATION_KEY}" --org="${RHSM_ORG}"
else
    echo "No activation key found, falling back to interactive registration"
    sudo subscription-manager register
fi

sudo subscription-manager attach --pool=8a85f99c7d76f2fd017d96c411c70667
sudo subscription-manager repos \
--enable "rhel-9-for-$(uname -m)-appstream-rpms" \
--enable "rhel-9-for-$(uname -m)-baseos-rpms" \
--enable "rhocp-$(get_ocp_version)-for-rhel-9-$(uname -m)-rpms"
