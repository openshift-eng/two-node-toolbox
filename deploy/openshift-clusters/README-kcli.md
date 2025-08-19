# OpenShift Two-Node Cluster Deployment with kcli

This guide covers deploying OpenShift two-node clusters using the kcli virtualization management tool. This approach provides an alternative to the dev-scripts method, offering simplified configuration and automated deployment workflows.

## Overview

The kcli deployment method automates OpenShift two-node cluster creation using **fencing topology** by default. Arbiter topology support is available for future releases.

## 1. Machine Requirements

**This section is identical to the main README.** Please refer to [section 1 of the main README](README.md#1-machine-requirements) for complete machine requirements including:

- Client machine requirements (Ansible)
- Remote machine requirements (RHEL 9, 64GB RAM, etc.)
- Optional AWS hypervisor setup

The same prerequisites apply whether using dev-scripts or kcli deployment methods.

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

### Automated Installation

The kcli-install role automatically handles target host setup including:
- Complete libvirt virtualization stack installation
- kcli package installation from COPR repository
- Default kcli configuration for local KVM hypervisor
- User permissions for libvirt group access

No manual kcli installation is required on the target host. 

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

The kcli deployment supports multiple configuration approaches with clear variable precedence.

### Configuration Methods

You can configure the deployment using any combination of these methods (in precedence order):

1. **Command line variables** (highest precedence)
2. **Playbook vars section**
3. **Variable override file** (`vars/kcli-install.yml`)
4. **Role defaults** (lowest precedence)

### Method 1: Variable Override File (Recommended for Persistent Configuration)

For persistent configuration that survives across deployments, use the variable override file:

```bash
# Copy and customize the example variables file
cp vars/kcli-install.yml my-kcli-config.yml
```

Edit your configuration file with your specific values:

```yaml
# my-kcli-config.yml - Custom cluster configuration
test_cluster_name: "production-edge-cluster"
domain: "edge.company.com"
topology: "fencing"

# OpenShift version
ocp_version: "stable"
ocp_tag: "4.20"

# VM specifications for production
vm_memory: 65536  # 64GB RAM
vm_numcpus: 32    # 32 CPU cores
vm_disk_size: 200 # 200GB disk

# Authentication: pull secret automatically read from role files/ directory
# SSH key automatically read from ~/.ssh/id_ed25519.pub on localhost

# Network configuration
network_name: "production"
api_ip: "10.100.50.100"
ingress_ip: "10.100.50.101"

# BMC configuration for fencing
bmc_user: "cluster-admin"
bmc_password: "secure-bmc-password"
```

**Important**: The override file must be explicitly imported in your playbook:

```yaml
# Custom playbook using override file
- hosts: localhost
  gather_facts: yes
  vars_files:
    - my-kcli-config.yml  # Your custom configuration
  roles:
    - kcli/kcli-install
```

### Method 2: Inline Playbook Variables

For one-off deployments or testing, define variables directly in the playbook:

```yaml
# inline-config-example.yml
- hosts: localhost
  gather_facts: yes
  vars:
    test_cluster_name: "test-cluster-01"
    topology: "fencing"
    domain: "test.lab.local"
    vm_memory: 32768
    vm_numcpus: 16
    ocp_tag: "4.20"
    # Pull secret automatically read from role files/pull-secret.json
  roles:
    - kcli/kcli-install
```

### Method 3: Command Line Overrides

Override any variable at runtime:

```bash
ansible-playbook kcli-install.yml \
  -e "test_cluster_name=emergency-cluster" \
  -e "vm_memory=49152"
```

### Variable Precedence Example

With this configuration hierarchy:
```
roles/kcli/kcli-install/defaults/main.yml:     vm_memory: 32768
vars/kcli-install.yml:                         vm_memory: 65536  
playbook vars:                                 vm_memory: 49152
command line:                                  -e "vm_memory=81920"
```

The final value will be: **81920** (command line has preference)

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
bmc_driver: "redfish"  # or "ipmi"
ksushy_port: 8000
```

## 5. Deployment

The deployment uses a **fencing topology** by default and runs non-interactively for consistent automation:

```bash
# Install required Ansible collections
ansible-galaxy collection install -r collections/requirements.yml

# Update inventory with your target host
cp inventory.ini.sample inventory.ini
# Edit inventory.ini with your host details

# Deploy fencing cluster (default)
ansible-playbook kcli-install.yml -i inventory.ini

# Deploy with custom cluster name
ansible-playbook kcli-install.yml -i inventory.ini \
  -e "test_cluster_name=prod-edge-cluster"

# Redeploy existing cluster (auto-cleanup first)
ansible-playbook kcli-install.yml -i inventory.ini \
  -e "force_cleanup=true"
```

## 6. Post-Deployment Access

### Accessing from Local Machine

Since the cluster runs on a remote host, you might need proxy configuration to access it from your local machine. After cluster installation, proxy setup will run to provide the same access as the dev-scripts (IPI) installation method.

## 7. Fencing Configuration (Post-Deployment)

After a successful kcli deployment with fencing topology, you need to configure stonith (STONITH = Shoot The Other Node In The Head) fencing to enable automatic node recovery.

### Understanding kcli Fencing vs Bare Metal

**Important:** kcli deployments use a different approach than bare metal deployments:

- **Bare Metal deployments** use BareMetalHost (BMH) custom resources that contain BMC connection details
- **kcli deployments** use virtual machines with simulated BMC functionality (ksushy) but don't create BMH resources

The existing `redfish.yml` playbook **will not work** with kcli deployments because it expects BMH resources that don't exist in virtualized environments.

### kcli Fencing Configuration

Use the specialized `kcli-redfish.yml` playbook designed for kcli deployments:

```bash
# Configure fencing for kcli-deployed cluster
ansible-playbook kcli-redfish.yml -i inventory.ini \
  -e "test_cluster_name=your-cluster-name" \
  -e "ksushy_ip=$(ansible_host_ip)" \
  -e "bmc_user=admin" \
  -e "bmc_password=admin123"
```

The kcli-redfish playbook will:
1. Discover cluster nodes from the OpenShift API
2. Calculate BMC endpoints using the ksushy simulator configuration  
3. Configure PCS stonith resources on each node
4. Enable stonith globally in the cluster

### Required Variables for kcli Fencing

| Variable | Description | Example |
|----------|-------------|---------|
| `test_cluster_name` | Name of your kcli cluster | `"edge-cluster-01"` |
| `ksushy_ip` | IP of the hypervisor running ksushy | `"192.168.1.100"` |
| `bmc_user` | BMC username from kcli config | `"admin"` |
| `bmc_password` | BMC password from kcli config | `"admin123"` |

### Automatic Variables

The kcli deployment automatically configures these values, which are used by the fencing setup:
- `ksushy_port`: Port for BMC simulator (default: 8000)
- BMC system IDs based on VM names (`{cluster-name}-ctlplane-{index}`)

### Why Not Use redfish.yml?

**Do NOT use the `redfish.yml` playbook** with kcli deployments. It will fail because:

```bash
# This will fail for kcli deployments
ansible-playbook redfish.yml  # ❌ Expects BMH resources that don't exist

# Use this instead for kcli deployments  
ansible-playbook kcli-redfish.yml  # ✅ Works with ksushy simulation
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
ssh your-host "kcli list vm"
ssh your-host "journalctl -u libvirtd"
```

**kcli Fencing issues:**
```bash
# Verify ksushy BMC simulator is running
ssh your-host "curl -s http://localhost:8000/redfish/v1/"

# Check stonith resources in cluster
source proxy.env
oc debug node/$(oc get nodes --no-headers -o custom-columns=NAME:.metadata.name | head -1) -- chroot /host pcs stonith status

# Test fencing manually (replace node name and cluster details)
oc debug node/your-node -- chroot /host pcs stonith fence your-node_redfish
```

### Monitoring Deployment Status

Check the status of an ongoing kcli installation using kcli's internal tracking mechanisms, from inside the host where it is being deployed:

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


### Redeployment

If you need to redeploy a cluster (either due to failure or configuration changes), use the `force_cleanup=true` parameter to automatically remove the existing cluster before deploying:

```bash
# Automatic cleanup and redeploy
ansible-playbook kcli-install.yml -i inventory.ini \
  -e "force_cleanup=true"
```

The `force_cleanup=true` parameter performs comprehensive cleanup before deployment:

1. **Cluster cleanup**: Attempts `kcli delete cluster openshift <cluster-name>` if the cluster exists
2. **VM cleanup**: Removes individual VMs (`<cluster-name>-ctlplane-0`, `<cluster-name>-ctlplane-1`, `<cluster-name>-arbiter`) if they exist
3. **Handles edge cases**: Works even if VMs exist but aren't tracked as a kcli cluster

This eliminates the need for manual cleanup steps in most scenarios.

**Note**: If you change the `test_cluster_name` between deployments, the automatic cleanup won't find the old cluster. In this case, you may need to manually remove the old cluster: `kcli delete cluster openshift <old-cluster-name>`

## 9. Advanced Configuration

### Custom Network Setup

```yaml
# Advanced network configuration
network_name: "production-network"
api_ip: "192.168.100.10"
ingress_ip: "192.168.100.11"
# kcli will create/configure the network as needed
```

### Multi-Version Testing

```yaml
# Test different OpenShift versions
configs:
  stable: { ocp_version: "stable", ocp_tag: "4.19" }
  candidate: { ocp_version: "candidate", ocp_tag: "4.20" }
  ci: { ocp_version: "ci", ocp_tag: "4.21" }
```

For additional advanced scenarios and troubleshooting, refer to the [kcli-install role documentation](roles/kcli/kcli-install/README.md).