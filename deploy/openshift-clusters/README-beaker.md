# External Host Initialization for Two-Node Toolbox

This document explains how to use the Two-Node Toolbox (TNF) on external RHEL hosts that are not provisioned through the AWS hypervisor automation. This workflow is designed for environments like Beaker, lab systems, or any pre-existing RHEL 9 hosts.

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
- Configures dev-scripts to use `/home/dev-scripts` instead of `/opt/dev-scripts`
- Ensures sufficient disk space for OpenShift cluster deployment (80GB+ required)

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

For fencing topology using the modern kcli method:

```bash
ansible-playbook kcli-install.yml -i inventory.ini
```

## Configuration Files

The initialization process creates several important configuration files in the dev-scripts working directory (`/home/dev-scripts`):

- **Cluster configuration**: Based on the topology you select during setup
- **Pull secrets**: OpenShift registry authentication
- **SSH keys**: For cluster node access
- **Network configuration**: Libvirt networking for VMs

## Troubleshooting

### Common Issues

**SSH Connection Problems**
- Verify SSH key authentication is working
- Check firewall settings on the target host
- Ensure the host IP in inventory.ini is correct

**Subscription Manager Errors**
- Verify activation key and organization ID are correct
- Ensure the host has internet access
- Check that your subscription includes OpenShift entitlements

**Insufficient Disk Space**
- The playbook configures dev-scripts to use `/home/dev-scripts`
- Ensure `/home` filesystem has at least 80GB free space
- Consider adding additional storage if needed

**Package Installation Failures**
- Verify all required repositories are enabled
- Check network connectivity to Red Hat repositories
- Ensure subscription is active and valid


## Next Steps

With your external host properly initialized, you can:

1. **Deploy OpenShift clusters** using the standard TNF playbooks
2. **Access cluster management** through the generated proxy configuration
3. **Scale and manage** your two-node deployments
4. **Configure fencing** for high availability scenarios

### Storage Considerations

If your host doesn't have sufficient space in `/home` (80GB+ required), you can customize the working directory by modifying the dev-scripts configuration files:

**For arbiter topology**, edit `roles/dev-scripts/install-dev/files/config_arbiter.sh`:
```bash
# Change the working directory to a location with more space
export WORKING_DIR="/path/to/larger/filesystem/dev-scripts"
```

**For fencing topology**, edit `roles/dev-scripts/install-dev/files/config_fencing.sh`:
```bash
# Change the working directory to a location with more space
export WORKING_DIR="/path/to/larger/filesystem/dev-scripts"
```

The `WORKING_DIR` variable controls where dev-scripts stores all cluster data, VM images, and working files. Ensure the chosen directory has:
- At least 80GB of free space
- Read/write permissions for the deployment user
- Fast storage for better performance

This workflow provides the same functionality as the AWS hypervisor path but allows you to use any RHEL 9 system as your deployment target.