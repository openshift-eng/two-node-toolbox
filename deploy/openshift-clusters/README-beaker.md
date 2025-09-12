# External Host Initialization for Two-Node Toolbox

This document explains how to use Two-Node Toolbox (TNT) to install Two-Node OpenShift clusters on external RHEL hosts that are not provisioned through the AWS hypervisor automation. This workflow is designed for environments like Beaker, lab systems, or any pre-existing RHEL 9 hosts.

## Overview

The `init-host.yml` playbook provides the same host initialization functionality as the AWS hypervisor creation scripts, preparing your external RHEL host to run OpenShift two-node cluster deployments. It replaces the AWS-specific initialization steps with Ansible automation that works on any RHEL 9 system.

## Prerequisites

### Host Requirements
- **Operating System**: RHEL 9.x with minimal installation
- **Hardware**: 64GB+ RAM, 500GB+ storage (with sufficient space in `/home`)
- **Network**: Internet access for package downloads and registry access
- **Access**: SSH access with sudo privileges

### Controller Requirements
- Ansible installed on your local machine
- SSH key pair for authentication
- Valid Red Hat subscription credentials (activation key recommended)

## Setup Process

### 1. Configure Inventory

Copy the sample inventory file and configure it with your host details:

```bash
cd deploy/openshift-clusters
cp inventory.ini.sample inventory.ini
```

Edit `inventory.ini` with your external host information:

```ini
[metal_machine]
root@your-host-ip ansible_ssh_extra_args='-o ServerAliveInterval=30 -o ServerAliveCountMax=120'

[metal_machine:vars]
ansible_become_password=""
```

**Important**: Replace `your-host-ip` with the actual IP address or hostname of your RHEL system.

### 2. Configure RHSM Credentials

You have several options for providing Red Hat subscription credentials:

#### Option A: Environment Variables (Recommended)
```bash
export RHSM_ACTIVATION_KEY="your-activation-key"
export RHSM_ORG="your-organization-id"
```
See [hands-off deployment](../aws-hypervisor/README.md#automated-rhsm-registration-hands-off-deployment) for more details on how to obtain these values

#### Option B: Local Variable File
```bash
cp vars/init-host.yml.sample vars/init-host.yml.local
# Edit vars/init-host.yml.local with your credentials
```

#### Option C: Command Line
```bash
ansible-playbook init-host.yml -i inventory.ini \
  -e "rhsm_activation_key=your-key" \
  -e "rhsm_org=your-org"
```

### 3. Run Host Initialization

Execute the initialization playbook:

```bash
# Using environment variables or local config file
ansible-playbook init-host.yml -i inventory.ini

# Or with command line parameters
ansible-playbook init-host.yml -i inventory.ini \
  -e "rhsm_activation_key=your-key" \
  -e "rhsm_org=your-org"
```

### 4. What the Playbook Does

The `init-host.yml` playbook performs the following tasks to replicate AWS hypervisor initialization:

#### Host Configuration
- Sets system hostname to match your deployment environment
- Adds SSH host keys to prevent connection prompts
- Creates `pitadmin` user with sudo access and random password

#### Subscription Management
- Configures Red Hat Subscription Manager
- Registers system using activation key or interactive credentials
- Enables required repositories:
  - RHEL 9 BaseOS and AppStream
  - OpenShift Container Platform repositories

#### Package Installation
- Installs essential development tools:
  - `git` - Required for dev-scripts
  - `make` - Essential for running dev-scripts Makefiles
  - `golang` - Required for Go-based tooling
  - `cockpit` - Web-based system management
  - `lvm2` - Logical volume management
  - `jq` - JSON processing tool

#### Storage Configuration
- If you need to configures dev-scripts to use a different path (`/home/dev-scripts` instead of `/opt/dev-scripts`, for example), add the following variable to your config_XXX.sh file
`export WORKING_DIR="/home/dev-scripts"`
- This might help you have sufficient disk space for OpenShift cluster deployment (80GB+ required)

## Transition to OpenShift Deployment

After successful host initialization, your external RHEL system is ready for OpenShift cluster deployment. You can now proceed with the standard Two-Node Toolbox workflow:

### Deploy Two-Node Cluster

Choose your preferred topology and run the setup playbook:

#### Arbiter Topology (Two-Node with Arbiter)
```bash
# Interactive mode
ansible-playbook setup.yml -i inventory.ini

# Non-interactive mode
ansible-playbook setup.yml -e "topology=arbiter" -e "interactive_mode=false" -i inventory.ini
```

#### Fencing Topology (Two-Node with Fencing)
```bash
# Non-interactive mode
ansible-playbook setup.yml -e "topology=fencing" -e "interactive_mode=false" -i inventory.ini
```

### Alternative: kcli-based Deployment

For fencing topology using kcli:

```bash
ansible-playbook kcli-install.yml -i inventory.ini
```