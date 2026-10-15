#!/usr/bin/env bash
# shellcheck source=/dev/null
source ~/profile.env

RHEL_MAJOR_VERSION=$(. /etc/os-release && echo "${VERSION_ID%%.*}")

sudo hostnamectl set-hostname "aws-${STACK_NAME}"

function get_ocp_version() {
    local latest_ga_ocp_version
    local default_version="${DEFAULT_OCP_VERSION:-}"
    if [[ -z "${default_version}" ]]; then
        case "${RHEL_MAJOR_VERSION}" in
            10) default_version="4.23" ;;
            *)  default_version="4.22" ;;
        esac
    fi
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

restore_repos_and_exit() {
    echo "ERROR: $1."
    if sudo test -d /etc/yum.repos.d.bak; then
        echo "Restoring pre-existing repo files."
        sudo rm -rf /etc/yum.repos.d
        sudo mv /etc/yum.repos.d.bak /etc/yum.repos.d
    else
        echo "No backup present (registration was already in place); leaving /etc/yum.repos.d untouched."
    fi
    exit 1
}

if sudo subscription-manager identity >/dev/null 2>&1; then
    echo "System already registered, skipping registration and repo wipe."
else
    if sudo test -d /etc/yum.repos.d.bak; then
        echo "Reusing pre-existing backup from an interrupted prior run."
    else
        staging=/etc/yum.repos.d.bak.partial
        sudo rm -rf "${staging}"
        if ! sudo cp -a /etc/yum.repos.d "${staging}"; then
            echo "ERROR: Failed to back up /etc/yum.repos.d. Aborting before wipe."
            sudo rm -rf "${staging}"
            exit 1
        fi
        if ! sudo mv "${staging}" /etc/yum.repos.d.bak; then
            echo "ERROR: Failed to publish backup to /etc/yum.repos.d.bak. Aborting before wipe."
            sudo rm -rf "${staging}"
            exit 1
        fi
        sudo rm -rf /etc/yum.repos.d/*
    fi

    # Use activation key for non-interactive registration if available
    if [ -n "${RHSM_ACTIVATION_KEY}" ] && [ -n "${RHSM_ORG}" ]; then
        echo "Using activation key for RHSM registration"
        sudo subscription-manager register --activationkey="${RHSM_ACTIVATION_KEY}" --org="${RHSM_ORG}" \
            || restore_repos_and_exit "subscription-manager register failed"
    else
        echo "No activation key found, falling back to interactive registration"
        sudo subscription-manager register \
            || restore_repos_and_exit "subscription-manager register failed"
    fi
fi

sudo subscription-manager config --rhsm.manage_repos=1 --rhsmcertd.disable=redhat-access-insights

sudo subscription-manager attach --pool=8a85f99c7d76f2fd017d96c411c70667 \
    || echo "WARNING: subscription-manager attach failed or is unsupported (e.g. RHEL 10); continuing — required repos are validated below."

sudo subscription-manager repos \
--enable "rhel-${RHEL_MAJOR_VERSION}-for-$(uname -m)-appstream-rpms" \
--enable "rhel-${RHEL_MAJOR_VERSION}-for-$(uname -m)-baseos-rpms" \
--enable "rhocp-$(get_ocp_version)-for-rhel-${RHEL_MAJOR_VERSION}-$(uname -m)-rpms" \
    || restore_repos_and_exit "subscription-manager repos --enable failed"

if sudo test -d /etc/yum.repos.d.bak; then
    if sudo cp -an /etc/yum.repos.d.bak/. /etc/yum.repos.d/; then
        sudo rm -rf /etc/yum.repos.d.bak
    else
        echo "ERROR: Failed to restore files from /etc/yum.repos.d.bak; keeping backup for manual recovery." >&2
        exit 1
    fi
fi

# Enable CodeReady Builder (CRB) repo for -devel packages (e.g. libvirt-devel).
# On RHUI instances (like AWS), subscription-manager repos --enable can't touch
# CRB at all (registered or not) because it's managed by the static RHUI repo
# file, not RHSM entitlements. dnf config-manager edits that file directly,
# which is what 'crb enable' itself wraps on non-RHUI hosts. RHEL_HOST_AMI can
# also point at a custom, RHSM-only AMI with no RHUI repo file at all, so fall
# back to subscription-manager for that case rather than assuming RHUI.
enable_crb_repo() {
    local arch
    arch=$(uname -m)
    local rhui_crb="codeready-builder-for-rhel-${RHEL_MAJOR_VERSION}-rhui-rpms"
    local rhsm_crb="codeready-builder-for-rhel-${RHEL_MAJOR_VERSION}-${arch}-rpms"

    if command -v crb &>/dev/null; then
        sudo crb enable
    else
        sudo dnf config-manager --set-enabled "${rhui_crb}" \
            || sudo subscription-manager repos --enable "${rhsm_crb}"
    fi
}

echo "Enabling CRB repository..."
if ! enable_crb_repo; then
    echo "ERROR: Failed to enable CRB repository. libvirt-devel will be unavailable."
    exit 1
fi
