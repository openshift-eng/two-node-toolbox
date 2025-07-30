# OpenShift Two-Node Cluster Deployment with kcli

This guide covers deploying OpenShift two-node clusters using the kcli virtualization management tool. This approach provides an alternative to the dev-scripts method, offering simplified configuration and automated deployment workflows.

## Overview

The kcli deployment method automates OpenShift two-node cluster creation with support for both **fencing** (now) and **arbiter** topologies (future released). It leverages kcli's OpenShift deployment capabilities to create production-ready clusters suitable for edge computing scenarios.

**Key advantages of kcli approach:**
- Simplified configuration management
- Built-in validation and error checking
- Automated BMC/fencing simulation
- Support for multiple virtualization providers
- Consistent variable management with existing dev-scripts workflows

## 1. Machine Requirements

**This section is identical to the main README.** Please refer to [section 1 of the main README](README.md#1-machine-requirements) for complete machine requirements including:

- Client machine requirements (Ansible)
- Remote machine requirements (RHEL 9, 64GB RAM, etc.)
- Optional AWS hypervisor setup

The same prerequisites apply whether using dev-scripts or kcli deployment methods.

## 2. Prerequisites

### kcli Installation

The target host must have kcli installed and configured:

```bash
# Install kcli (on target host)
curl -s https://get.kcli.sh | bash
# or 
pip3 install kcli

# Verify installation
kcli list pool
kcli list network
```

### OpenShift Requirements

- **Pull Secret**: Download from https://cloud.redhat.com/openshift/install/pull-secret
  - For CI builds: Ensure pull secret includes `registry.ci.openshift.org` access
  - Standard pull secrets from console.redhat.com may not include CI registry access
- **SSH Key**: For cluster access (default: `~/.ssh/id_rsa.pub`)

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
topology: "fencing"  # or "arbiter"

# OpenShift version
ocp_version: "stable"
ocp_tag: "4.20"

# VM specifications for production
vm_memory: 65536  # 64GB RAM
vm_numcpus: 32    # 32 CPU cores
vm_disk_size: 200 # 200GB disk

# Custom authentication
pull_secret_path: "/opt/secrets/production-pull-secret.json"
ssh_public_key_path: "/opt/keys/production-cluster-key.pub"

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
    pull_secret_path: "{{ ansible_user_dir }}/pull-secret.json"
  roles:
    - kcli/kcli-install
```

### Method 3: Command Line Overrides

Override any variable at runtime:

```bash
ansible-playbook kcli-install.yml \
  -e "test_cluster_name=emergency-cluster" \
  -e "topology=arbiter" \
  -e "vm_memory=49152"
```

### Variable Precedence Example

With this configuration hierarchy:
```
defaults/main.yml:     vm_memory: 32768
vars/kcli-install.yml: vm_memory: 65536  
playbook vars:         vm_memory: 49152
command line:          -e "vm_memory=81920"
```

The final value will be: **81920** (command line wins)

## 4. Core Configuration Variables

### Required Variables

| Variable | Description | Example |
|----------|-------------|---------|
| `test_cluster_name` | Cluster identifier | `"edge-cluster-01"` |
| `topology` | Cluster type | `"fencing"` or `"arbiter"` |
| `domain` | Base domain | `"edge.company.com"` |
| `pull_secret_path` | Pull secret location | `"~/pull-secret.json"` |

### Common Configuration Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `vm_memory` | `32768` | Memory per node (MB) |
| `vm_numcpus` | `16` | CPU cores per node |
| `vm_disk_size` | `120` | Disk size per node (GB) |
| `ocp_version` | `"ci"` | OpenShift version channel |
| `ocp_tag` | `"4.20"` | Specific version tag |
| `network_name` | `"default"` | kcli network name |
| `bmc_user` | `"admin"` | BMC username (fencing) |
| `bmc_password` | `"admin"` | BMC password (fencing) |

### Topology-Specific Variables

**Fencing Topology:**
```yaml
topology: "fencing"
bmc_user: "admin"
bmc_password: "secure-password"
bmc_driver: "redfish"  # or "ipmi"
ksushy_port: 8000
```

**Arbiter Topology:**
```yaml
topology: "arbiter"
arbiter_memory: 16384  # Arbiter node memory (MB)
```

## 5. Deployment

### Interactive Deployment (Default)

The provided `kcli-install.yml` playbook supports interactive mode:

```bash
# Update inventory with your target host
cp inventory.ini.sample inventory.ini
# Edit inventory.ini with your host details

# Run interactive deployment
ansible-playbook kcli-install.yml -i inventory.ini
```

The playbook will:
1. Prompt for topology selection (arbiter or fencing)
2. Display configuration summary
3. Request confirmation before proceeding
4. Deploy the cluster

### Non-Interactive Deployment

For automation, disable interactive prompts:

```bash
# Deploy fencing cluster
ansible-playbook kcli-install.yml -i inventory.ini \
  -e "topology=fencing" \
  -e "interactive_mode=false"

# Deploy arbiter cluster with custom variables
ansible-playbook kcli-install.yml -i inventory.ini \
  -e "topology=arbiter" \
  -e "interactive_mode=false" \
  -e "test_cluster_name=prod-arbiter-01"
```

### Using Custom Configuration Files

Deploy with your custom configuration:

```bash
# Create custom playbook
cat > deploy-production.yml << EOF
- hosts: localhost
  gather_facts: yes
  vars:
    interactive_mode: false
  vars_files:
    - my-production-config.yml
  roles:
    - kcli/kcli-install
EOF

# Deploy
ansible-playbook deploy-production.yml -i inventory.ini
```

## 6. Post-Deployment Access

### Cluster Access

After successful deployment:

```bash
# Set kubeconfig (replace cluster name as needed)
export KUBECONFIG=~/.kcli/clusters/your-cluster-name/auth/kubeconfig

# Verify cluster
oc get nodes
oc get clusteroperators
```

### Console Access

The OpenShift web console is available at:
```
https://console-openshift-console.apps.<cluster_name>.<domain>
```

Login credentials:
- **Username**: `kubeadmin`
- **Password**: Found in `~/.kcli/clusters/<cluster_name>/auth/kubeadmin-password`

### Accessing from Local Machine

Since the cluster runs on a remote host, you'll need proxy configuration to access it from your local machine. The main dev-scripts README covers proxy setup in detail.

## 7. Common Deployment Scenarios

### Development Environment

```yaml
# dev-config.yml
test_cluster_name: "dev-cluster"
topology: "fencing"
domain: "dev.lab.local"
vm_memory: 32768
vm_numcpus: 16
ocp_version: "ci"
ocp_tag: "4.20"
force_cleanup: true  # Allow easy redeployment
kcli_debug: true     # Verbose output
```

### Production Environment

```yaml
# prod-config.yml
test_cluster_name: "prod-edge-site-01"
topology: "arbiter"
domain: "edge.company.com"
vm_memory: 65536
vm_numcpus: 32
vm_disk_size: 200
ocp_version: "stable"
ocp_tag: "4.19"
pull_secret_path: "/opt/secrets/prod-pull-secret.json"
ssh_public_key_path: "/opt/keys/prod-cluster-key.pub"
```

### CI/CD Integration

```bash
# Automated CI deployment
ansible-playbook kcli-install.yml \
  -i inventory.ini \
  -e "topology=fencing" \
  -e "interactive_mode=false" \
  -e "test_cluster_name=ci-test-$(date +%Y%m%d-%H%M)" \
  -e "force_cleanup=true" \
  -e "ci_token=${CI_REGISTRY_TOKEN}"
```

## 8. Troubleshooting

### Common Issues

**kcli not found:**
```bash
# Verify kcli installation on target host
ssh your-host "which kcli && kcli version"
```

**Pull secret issues:**
```bash
# Verify pull secret format
jq . < pull-secret.json
# For CI builds, check registry access
jq '.auths | has("registry.ci.openshift.org")' < pull-secret.json
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

### Validation Commands

```bash
# Verify cluster deployment
export KUBECONFIG=~/.kcli/clusters/your-cluster/auth/kubeconfig
oc get nodes
oc get clusteroperators
oc get bmh -A  # For fencing topology
```

### Force Cleanup and Retry

```bash
# Clean up failed deployment
ssh your-host "kcli delete cluster openshift your-cluster --yes"

# Redeploy with force cleanup
ansible-playbook kcli-install.yml -i inventory.ini \
  -e "force_cleanup=true" \
  -e "interactive_mode=false"
```

## 9. Differences from dev-scripts Approach

| Aspect | kcli Approach | dev-scripts Approach |
|--------|---------------|----------------------|
| **Configuration** | Ansible variables + override files | Shell config files |
| **Deployment** | Single playbook execution | Multi-step make commands |
| **Validation** | Built-in Ansible validation | Manual verification |
| **State Management** | Automatic via kcli | Manual via dev-scripts |
| **Provider Support** | Multiple via kcli | Primarily libvirt/KVM |
| **Customization** | Variable override patterns | Config file modification |

## 10. Advanced Configuration

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

### Resource Scaling

```yaml
# Scale resources based on workload
small: { vm_memory: 32768, vm_numcpus: 16, vm_disk_size: 120 }
medium: { vm_memory: 49152, vm_numcpus: 24, vm_disk_size: 150 }
large: { vm_memory: 65536, vm_numcpus: 32, vm_disk_size: 200 }
```

For additional advanced scenarios and troubleshooting, refer to the [kcli-install role documentation](roles/kcli/kcli-install/README.md). 