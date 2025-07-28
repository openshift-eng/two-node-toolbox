# kcli-install Role

This role deploys OpenShift two-node clusters with fencing using kcli virtualization management tool.

## Description

The kcli-install role automates the deployment of OpenShift two-node clusters with automatic fencing configuration. It leverages kcli's OpenShift deployment capabilities to create a production-ready two-node cluster suitable for edge computing scenarios.

This role is equivalent to running:
```bash
kcli create cluster openshift -P ctlplanes=2 -P version=ci -P tag='4.20' <cluster-name>
```

But adds comprehensive validation, error checking, and post-deployment verification.

**Consistent with install-dev role**: This role follows the same patterns as the existing `install-dev` role, using identical variable names (`test_cluster_name`, `topology`) and state management for seamless integration.

Key features:
- Automated two-node OpenShift deployment with fencing or arbiter
- Configurable VM specifications and networking
- Integration with kcli's BMC/Redfish simulation for fencing
- Comprehensive validation and error checking
- Post-deployment verification and cluster health checks
- State management consistent with install-dev role
- Support for both interactive and non-interactive deployment

## Requirements

- kcli installed and configured with a virtualization provider (KVM/libvirt recommended)
- OpenShift pull secret from Red Hat
  - For CI builds: Pull secret must include `registry.ci.openshift.org` access
  - Regular pull secret from console.redhat.com may not include CI registry access
- SSH key pair for cluster access
- Sufficient system resources (minimum 64GB RAM, 240GB storage for two nodes)
- Network connectivity for OpenShift image downloads
  - For CI builds: Access to `registry.ci.openshift.org`

## Role Variables

### Required Variables

- `test_cluster_name`: OpenShift cluster name (consistent with install-dev role)
- `topology`: Cluster topology - "fencing" or "arbiter" (matches install-dev role)
- `domain`: Base domain for the cluster
- `pull_secret_path`: Path to OpenShift pull secret file
- `ssh_public_key_path`: Path to SSH public key file

### Cluster Configuration

- `topology`: Deployment topology (required)
  - "fencing": Two-node cluster with automatic fencing (DevPreviewNoUpgrade)
  - "arbiter": Two-node cluster with arbiter node (TechPreviewNoUpgrade)
- `ctlplanes`: Number of control plane nodes (default: 2, required for two-node)
- `workers`: Number of worker nodes (default: 0 for two-node configuration)
- `cluster_network_type`: OpenShift network type (default: "OVNKubernetes")
- `install_dev_mode`: Installation mode - "install" or "redeploy" (default: "install")

### VM Specifications

- `vm_memory`: Memory per node in MB (default: 32768)
- `vm_numcpus`: CPU cores per node (default: 16)
- `vm_disk_size`: Disk size per node in GB (default: 120)

### OpenShift Version

- `ocp_version`: OpenShift version channel (default: "ci")
  - "stable": Released versions
  - "ci": Latest development/CI builds (requires CI registry access)
  - "candidate": Release candidates
  - "nightly": Nightly builds
- `ocp_tag`: Specific OpenShift version tag (default: "4.20")
- `openshift_release_image`: Optional override for specific release image
- `ci_token`: CI token for CI builds (required when openshift_ci=false)
- `openshift_ci`: Set to true to avoid CI_TOKEN (has side effects, default: false)

### Network Configuration

- `network_name`: kcli network to use (default: "default")
- `api_ip`: Specific API IP address (optional, auto-detected if empty)
- `ingress_ip`: Specific ingress IP address (optional, uses api_ip if empty)

### BMC/Fencing Configuration

- `bmc_user`: BMC username (default: "admin")
- `bmc_password`: BMC password (default: "admin")
- `bmc_driver`: BMC driver type - "redfish" or "ipmi" (default: "redfish")
- `ksushy_ip`: IP address for ksushy BMC simulator (default: ansible_default_ipv4.address)
- `ksushy_port`: Port for ksushy BMC simulator (default: 8000)

### Arbiter Configuration (when topology="arbiter")

- `enable_arbiter`: Automatically set to "true" for arbiter topology
- `arbiter_memory`: Memory for arbiter node in MB (default: 16384)

### Deployment Options

- `kcli_threaded`: Enable threaded deployment (default: true)
- `kcli_async`: Enable async deployment (default: false)
- `kcli_debug`: Enable kcli debug output (default: false)
- `force_cleanup`: Remove existing cluster before deployment (default: false)

## Dependencies

- kcli package installed on the control node
- Configured kcli virtualization provider
- Access to Red Hat registry or disconnected registry

## Example Playbook

```yaml
- hosts: localhost
  gather_facts: yes
  vars:
    test_cluster_name: "edge-cluster-01"
    topology: "fencing"  # or "arbiter"
    domain: "example.corp"
    pull_secret_path: "{{ ansible_user_dir }}/pull-secret.json"
    vm_memory: 32768
    vm_numcpus: 16
    ocp_tag: "4.20"
  roles:
    - kcli-install
```

## Usage

### Interactive Mode (Default)

1. Ensure kcli is installed and configured:
```bash
kcli list pool
kcli list network
```

2. Download OpenShift pull secret to `~/pull-secret.json`
   - For CI builds: Ensure pull secret includes `registry.ci.openshift.org` access

3. Run the playbook (will prompt for topology):
```bash
ansible-playbook kcli-install.yml
```

4. Access the deployed cluster:
```bash
export KUBECONFIG=~/.kcli/clusters/edge-cluster-01/auth/kubeconfig
oc get nodes
```

### Non-Interactive Mode

For automation, specify topology and disable interactive mode:

```bash
# Deploy fencing cluster
ansible-playbook kcli-install.yml \
  -e "topology=fencing" \
  -e "interactive_mode=false"

# Deploy arbiter cluster  
ansible-playbook kcli-install.yml \
  -e "topology=arbiter" \
  -e "interactive_mode=false"
```

## Manual kcli Command Equivalent

This role automates the equivalent of:
```bash
kcli create cluster openshift -P ctlplanes=2 -P version=ci -P tag='4.20' <cluster-name>
```

The role adds value through:
- Pre-deployment validation and error checking
- Automatic BMC/fencing configuration
- Post-deployment verification
- Consistent configuration management
- Proper cleanup and error handling
- State management consistent with install-dev role
- Support for both fencing and arbiter topologies

## Validation

The role performs comprehensive validation:
- kcli installation and configuration
- OpenShift pull secret availability
- SSH key accessibility
- Resource requirements
- Cluster naming conflicts
- Two-node configuration compliance
- CI registry access validation (for CI builds)
- Topology-specific configuration validation

## Post-Deployment

After successful deployment:
- Cluster kubeconfig is available at `~/.kcli/clusters/<cluster_name>/auth/kubeconfig`
- Web console accessible at `https://console-openshift-console.apps.<cluster_name>.<domain>`
- Fencing automatically configured for both control plane nodes (fencing topology)
- Arbiter node configured for quorum management (arbiter topology)
- All cluster operators should be available and healthy
- Cluster state tracked in JSON format for consistency with install-dev role

## Cleanup

To remove the deployed cluster:
```bash
kcli delete cluster openshift <cluster_name> --yes
```

## Troubleshooting

- Check kcli logs for deployment issues
- Verify network connectivity and DNS resolution
- Ensure sufficient resources on the hypervisor
- Validate pull secret format and permissions
- Review BMC simulator logs for fencing issues
- For CI builds: Verify access to `registry.ci.openshift.org`
- Check cluster state file for deployment status consistency 