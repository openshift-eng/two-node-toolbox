# OpenShift Two-Node Cluster Deployment with kcli

This guide covers deploying OpenShift two-node clusters using the kcli virtualization management tool. This approach provides a way of testing UPI deployments which is not available through the dev-scripts method.

## Overview

The kcli deployment method automates OpenShift two-node cluster creation using **fencing topology** by default. Arbiter topology support will be available for future releases.

## 1. Machine Requirements

**This section is identical to the main README.** Please refer to [section 1 of the main README](README.md#1-machine-requirements) for complete machine requirements including:

- Client machine requirements (Ansible)
- Remote machine requirements (RHEL 9, 64GB RAM, etc.)
- Optional AWS hypervisor setup

The same prerequisites apply whether using dev-scripts or kcli deployment methods. If you're using a baremetal server not provisioned through the aws-hypervisor directory, please see the appropiate [README](README-external-host.md) to know how to run the init-host.yml playbook

## 2. Prerequisites

### Ansible Collections

Install required Ansible collections on the client machine (where you run ansible-playbook):

```bash
ansible-galaxy collection install -r collections/requirements.yml
```

This installs:
- `community.libvirt`: For libvirt virtualization management  
- `kubernetes.core`: For Kubernetes resource management
- `containers.podman`: For container operations
- `ansible.posix`: Some systems might need this for certain system-level operations

### Automated Installation

The kcli-install role automatically handles target host setup including:
- Complete libvirt virtualization stack installation
- kcli package installation from COPR repository
- Default kcli configuration for local KVM hypervisor
- User permissions for libvirt group access

### OpenShift Requirements

- **Pull Secret**: Download from https://cloud.redhat.com/openshift/install/pull-secret
  - For CI builds: Ensure pull secret includes `registry.ci.openshift.org` access
  - Standard pull secrets from console.redhat.com may not include CI registry access
- **SSH Key**: For cluster access (default: `~/.ssh/id_ed25519.pub`)

### Authentication File Setup

#### Pull Secret

Place your pull secret in the role files directory:

```bash
# Navigate to the kcli-install files directory
cd roles/kcli/kcli-install/files/

# Create pull secret file (paste your pull secret content)
cat > pull-secret.json << EOF
{"auths":{"your-pull-secret-content-here"}}
EOF
```

The deployment will automatically copy the pull secret from the files directory to the remote host during deployment.

#### SSH Key (Automatic from Localhost)
The deployment automatically reads your SSH public key from `~/.ssh/id_ed25519.pub` on your **local machine** (ansible controller) and:
1. Copies it to the remote host for kcli cluster deployment
2. Installs it as an authorized key for SSH access

If you don't have an SSH key on your local machine, generate one:
```bash
# Generate SSH key pair on your local machine
ssh-keygen -t ed25519 -f ~/.ssh/id_ed25519
```

**Note**: The SSH key must exist on the machine where you run ansible, not on the remote host.

## 3. Configuration

The kcli deployment supports multiple configuration approaches with clear variable precedence. It is recommended that you create 

### Configuration Methods

You can configure the deployment using any combination of these methods (in precedence order). 

1. **Command line variables** (highest precedence)
2. **Playbook vars section**
3. **Role defaults** (lowest precedence) (`roles/kcli/kcli-install/defaults/main.yml`)

For simple overrides, the command line is recommended. For setting your preferred permanent config, copy [kcli.yml.template](vars/kcli.yml.template) to [kcli.yml](vars/kcli.yml) and update the values to your preference. This file is not tracked by Git and will persist between TNT updates. 

You can find more information on the official ansible documentation https://docs.ansible.com/ansible/latest/playbook_guide/playbooks_variables.html:

#### Command Line Overrides

Override any variable at runtime:

```bash
ansible-playbook kcli-install.yml \
  -e "test_cluster_name=emergency-cluster" \
  -e "vm_memory=49152"
```



## 4. Core Configuration Variables

### Required Variables

| Variable | Description | Example |
|----------|-------------|---------|
| `test_cluster_name` | Cluster identifier | `"edge-cluster-01"` |
| `topology` | Cluster type | `"fencing"` (default) |
| `domain` | Base domain | `"edge.company.com"` |

### Common Configuration Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `vm_memory` | `32768` | Memory per node (MB) |
| `vm_numcpus` | `16` | CPU cores per node |
| `vm_disk_size` | `120` | Disk size per node (GB) |
| `ocp_version` | `"stable"` | OpenShift version channel |
| `ocp_tag` | `"4.19"` | Specific version tag |
| `network_name` | `"default"` | kcli network name |
| `bmc_user` | `"admin"` | BMC username (fencing) |
| `bmc_password` | `"admin123"` | BMC password (fencing) |
| `force_cleanup` | `false` | Auto-remove existing cluster before deploy |

### Topology-Specific Variables

**Fencing Topology:**
```yaml
topology: "fencing"
bmc_user: "admin"
bmc_password: "admin123"
bmc_driver: "redfish"  
ksushy_port: 8000
```

## 5. Deployment

The deployment uses a **fencing topology** by default and runs non-interactively for consistent automation:

```bash
# Install required Ansible collections
ansible-galaxy collection install -r collections/requirements.yml

# Update inventory with your target host (if not using the automatic inventory management)
cp inventory.ini.sample inventory.ini
# Edit inventory.ini with your host details

# Deploy fencing cluster (default)
ansible-playbook kcli-install.yml -i inventory.ini

# Deploy with custom cluster name
ansible-playbook kcli-install.yml -i inventory.ini \
  -e "test_cluster_name=prod-edge-cluster"

```

To redeploy a cluster, check the [redeployment](#9-redeployment) section

## 6. Post-Deployment Access

### Accessing from Local Machine

Since the cluster runs on a remote host, you might need proxy configuration to access it from your local machine. After cluster installation, proxy setup will run to provide the same access as the dev-scripts (IPI) installation method.

### Alternative: Direct Access from Hypervisor

For direct cluster access **from within the hypervisor host** (not from your local machine), authentication files are automatically copied to a standard location:

```
~/auth/kubeconfig          # Cluster admin kubeconfig  
~/auth/kubeadmin-password   # Default admin password
```

**From the hypervisor host only**, you can access the cluster directly:
```bash
# SSH into the hypervisor first
ssh your-hypervisor-host

# Option 1: Use default kubeconfig location (recommended)
oc get nodes

# Option 2: Explicitly set KUBECONFIG environment variable
export KUBECONFIG=~/auth/kubeconfig
oc get nodes

# Get admin password for web console
cat ~/auth/kubeadmin-password
```

The deployment automatically creates a symlink from `~/.kube/config` to `~/auth/kubeconfig`, so `oc` commands work without setting the `KUBECONFIG` environment variable.

**Note**: This direct access only works from within the hypervisor. For access from your local machine, use the proxy setup described above.

### CI Builds

For deploying unreleased or development OpenShift builds, kcli supports CI builds from `registry.ci.openshift.org`:

```yaml
# CI build configuration
ocp_version: "ci"
ocp_tag: "4.20"  # Target version
```

**Requirements for CI builds:**
1. **Enhanced Pull Secret**: Your pull secret must include `registry.ci.openshift.org` access
2. **No CI Token Required**: Unlike dev-scripts, kcli does not use `CI_TOKEN` environment variables

**Getting CI Registry Access:**
1. Visit https://console-openshift-console.apps.ci.l2s4.p1.openshiftapps.com
2. Log in with your Red Hat account
3. Click your name → "Copy login command" → "Display Token" 
4. Use the provided registry credentials to update your pull secret

**Example CI deployment:**
```bash
# Deploy latest CI build
ansible-playbook kcli-install.yml -i inventory.ini \
  -e "ocp_version=ci" \
  -e "ocp_tag=4.20" \
  -e "interactive_mode=false"
```

**Verify CI registry access:**
```bash
# Check if your pull secret includes CI registry
jq '.auths | has("registry.ci.openshift.org")' < roles/kcli/kcli-install/files/pull-secret.json
```

## 7. Fencing Configuration (Post-Deployment)

After a successful 4.19 kcli deployment with fencing topology, STONITH fencing needs to be configured to enable automatic node recovery. *If you are using the kcli-install playbook, this will be done for you automatically via kcli-redfish.yml**. If you're doing it some other way, you can use the kcli-redfish,yml playbook manually.

The existing `redfish.yml` playbook **will not work** with kcli deployments because it expects BMH resources that don't exist in virtualized environments.

### kcli Fencing Configuration

The specialized `kcli-redfish.yml` playbook is designed for kcli deployments. **All configuration is automatically detected** - no manual variables required:

```bash
# Configure fencing for kcli-deployed cluster (fully automatic)
ansible-playbook kcli-redfish.yml -i inventory.ini
```

The kcli-redfish playbook automatically:
1. **Detects cluster name** from running kcli clusters or kcli-install defaults
2. **Uses hypervisor IP** from ansible inventory host  
3. **Pulls BMC credentials** from kcli-install role defaults
4. **Discovers cluster nodes** from the OpenShift API
5. **Calculates BMC endpoints** using the ksushy simulator configuration
6. **Configures PCS stonith resources** on each node
7. **Enables stonith globally** in the cluster

### Default Configuration

The playbook uses reasonable defaults that work for typical kcli deployments:

| Variable | Default Value | Description |
|----------|---------------|-------------|
| `test_cluster_name` | `tnt-cluster` | From kcli-install defaults |
| `ksushy_ip` | `192.168.122.1` | Standard libvirt network gateway |
| `bmc_user` | `admin` | From kcli-install defaults |
| `bmc_password` | `admin123` | From kcli-install defaults |
| `ksushy_port` | `8000` | From kcli-install defaults |

These defaults work for standard kcli deployments where VMs use the default libvirt network (`192.168.122.x/24`).

### Why Not Use redfish.yml?

**Do not use the `redfish.yml` playbook** with kcli deployments. It will fail because:

```bash
# This will fail for kcli deployments
ansible-playbook redfish.yml  # Expects BMH resources that don't exist

# Use this instead for kcli deployments  
ansible-playbook kcli-redfish.yml  # Uses defaults optimized for kcli
```

## 8. Troubleshooting

### Common Issues

**kcli installation issues:**
```bash
# The role automatically installs kcli, but you can verify:
ssh your-host "which kcli && kcli version"
# Check libvirt connectivity
ssh your-host "virsh list --all"
```

**Pull secret issues:**
```bash
# Verify pull secret format
jq . < roles/kcli/kcli-install/files/pull-secret.json
# For CI builds, check registry access
jq '.auths | has("registry.ci.openshift.org")' < roles/kcli/kcli-install/files/pull-secret.json
```

**Resource constraints:**
```bash
# Check available resources on target host
ssh your-host "free -h && df -h"
```

**Deployment failures:**
```bash
# Check kcli logs
ssh {your-host} "kcli list vm"
ssh {your-host} "journalctl -u libvirtd"
```

### kcli Fencing Issues

Note: Remember to `source proxy.env` before any `oc` commands if you're using the integrated proxy pod. 

**Network connectivity**:
```bash
# Check that VMs can reach ksushy on the default IP (192.168.122.1)
oc debug node/$(oc get nodes --no-headers -o custom-columns=NAME:.metadata.name | head -1) -- chroot /host curl -s http://192.168.122.1:8000/redfish/v1/

# Check what gateway IP the VMs actually use
oc debug node/$(oc get nodes --no-headers -o custom-columns=NAME:.metadata.name | head -1) -- chroot /host ip route show default
```

**Cluster fencing diagnostics**:
```bash
# Check stonith resources in cluster

oc debug node/$(oc get nodes --no-headers -o custom-columns=NAME:.metadata.name | head -1) -- chroot /host pcs stonith status

# Test fencing manually (replace node name and cluster details)
oc debug node/your-node -- chroot /host pcs stonith fence your-node_redfish
```

**Note**: If your kcli deployment uses a non-standard network, override the `ksushy_ip` parameter to match your libvirt gateway IP.

### Monitoring Deployment Status

Check the status of an ongoing kcli installation using kcli's internal tracking mechanisms. Run this from inside the host where it is being deployed:

```bash
# List all clusters managed by kcli
kcli list cluster

# List VMs associated with your cluster
kcli list vm | grep {cluster-name}

# Check cluster directory exists and contents
ls -la ~/.kcli/clusters/{cluster-name}/

# Monitor the OpenShift installation log in real-time
tail -f ~/.kcli/clusters/{cluster-name}/.openshift_install.log
```

**Key status indicators:**
- **Deployment started**: `~/.kcli/clusters/{cluster}/` directory exists
- **Parameters configured**: `kcli_parameters.yml` file present
- **VMs running**: VMs appear in `kcli list vm` output
- **Installation progress**: Activity in `.openshift_install.log`
- **Deployment complete**: `auth/kubeconfig` file created


## 9. Redeployment

If you need to redeploy a cluster (either due to failure or configuration changes), use the `force_cleanup=true` parameter to automatically remove the existing cluster before deploying:

```bash
# Automatic cleanup and redeploy
ansible-playbook kcli-install.yml -i inventory.ini \
  -e "force_cleanup=true"
```

The `force_cleanup=true` parameter performs comprehensive cleanup before deployment:

1. **Cluster cleanup**: Attempts `kcli delete cluster openshift <cluster-name>` if the cluster exists
2. **VM cleanup**: Removes individual VMs (`{cluster-name}-ctlplane-0`, `{cluster-name}-ctlplane-1`, `{cluster-name}-arbiter`) if they exist
3. **Handles edge cases**: Works even if VMs exist but aren't tracked as a kcli cluster

This eliminates the need for manual cleanup steps in most scenarios.

**Note**: If you change the `test_cluster_name` between deployments, the automatic cleanup won't find the old cluster. In this case, you may need to manually remove the old cluster: `kcli delete cluster openshift {old-cluster-name}`

## 10. Advanced Configuration

### Custom Network Setup

```yaml
# Advanced network configuration
network_name: "production-network"
api_ip: "192.168.100.10"
ingress_ip: "192.168.100.11"
# kcli will create/configure the network as needed
```

For additional advanced scenarios and troubleshooting, refer to the [kcli-install role documentation](roles/kcli/kcli-install/README.md).