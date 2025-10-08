# kcli-install Role

This role deploys OpenShift two-node clusters with fencing using kcli virtualization management tool.

## Description

The kcli-install role automates the deployment of OpenShift two-node clusters with automatic fencing configuration. It leverages kcli's OpenShift deployment capabilities to create a production-ready two-node cluster suitable for edge computing scenarios.

This role is equivalent to running, for example:
```bash
kcli create cluster openshift -P ctlplanes=2 -P version=ci -P tag='4.20' <cluster-name>
```

But adds comprehensive validation and error checking.

**Consistent with install-dev role**: This role follows the same patterns as the existing `install-dev` role, using identical variable names (`test_cluster_name`, `topology`) and state management for seamless integration.

Key features:
- Automated two-node OpenShift deployment with fencing or arbiter (future release)
- Configurable VM specifications and networking
- Integration with kcli's BMC/Redfish use of libvirt and sushytools for fencing (ksushy)
- Support for both interactive and non-interactive deployment
- Automatic proxy setup for cluster access in restricted environments

## Requirements

### System Requirements

- CentOS 9 or RHEL 9 host (Rocky Linux/Alma Linux supported on best effort basis)
- Minimum 64GB RAM, 240GB storage for two nodes
- User with passwordless sudo access
- libvirt/KVM virtualization support enabled in BIOS

### OpenShift Requirements

See the [general kcli README](../../../README-kcli.md#openshift-requirements) OpenShift Requirements section

### Ansible Collections

Required Ansible collections (install with `ansible-galaxy collection install -r collections/requirements.yml`):

- `community.libvirt>=1.3.0`: For libvirt virtualization management
- `kubernetes.core>=2.4.0`: For Kubernetes resource management
- `containers.podman>=1.10.0`: For container operations

**Note**: The role automatically installs and configures the complete libvirt virtualization stack if not already present.

### Authentication File Handling

This role follows the same authentication file conventions as the dev-scripts role for consistency:

- **Pull Secret**: Must be placed in role `files/pull-secret.json` and will be automatically copied to remote host user home directory
- **SSH Key**: Read from localhost (`~/.ssh/id_ed25519.pub` on ansible controller) and copied to remote host for kcli, plus installed as authorized key via config role

## Role Variables

### Required Variables

- `test_cluster_name`: OpenShift cluster name (consistent with install-dev role)
- `topology`: Cluster topology - "fencing" or "arbiter" (matches install-dev role)
- `domain`: Base domain for the cluster
- `pull_secret_path`: Path to OpenShift pull secret file in role files directory (default: `{{ role_path }}/files/pull-secret.json`)
  - Place your pull secret as `pull-secret.json` in the `files/` directory

### Cluster Configuration

- `topology`: Deployment topology (required)
  - "fencing": Two-node cluster with automatic fencing 
  - "arbiter": Two-node cluster with arbiter node (not supported yet)
- `ctlplanes`: Number of control plane nodes (default: 2, required for two-node)
- `workers`: Number of worker nodes (default: 0 for two-node configuration)
- `cluster_network_type`: OpenShift network type (default: "OVNKubernetes")

### VM Specifications

- `vm_memory`: Memory per node in MB (default: 32768)
- `vm_numcpus`: CPU cores per node (default: 16)
- `vm_disk_size`: Disk size per node in GB (default: 120)

### OpenShift Version
See [defaults](../kcli-install/defaults/main.yml.template) for default values

If you're installing a specific openshift release image, you will need to set the proper channel in ocp_version
- `ocp_version`: OpenShift version channel
  - "stable": Released versions
  - "ci": Latest development/CI builds (requires CI registry access)
  - "candidate": Release candidates
  - "nightly": Nightly builds


- `ocp_tag`: Specific OpenShift version tag 

 >If you're installing a specific openshift release image which is not generally available, you will need to set the proper channel in ocp_version
- `openshift_release_image`: Optional override for specific release image

### Network Configuration

- `network_name`: kcli network to use (default: "default")
- `api_ip`: Specific API IP address (optional, auto-detected if empty)
- `ingress_ip`: Specific ingress IP address (optional, uses api_ip if empty)

### BMC/Fencing Configuration

- `bmc_user`: BMC username (default: "admin")
- `bmc_password`: BMC password (default: "admin123")
- `bmc_driver`: BMC driver type - "redfish" or "ipmi" (default: "redfish")
- `ksushy_ip`: IP address for ksushy BMC simulator (default: ansible_default_ipv4.address)
- `ksushy_port`: Port for ksushy BMC simulator (default: 9000)

### Arbiter Configuration (when topology="arbiter")

- `enable_arbiter`: Automatically set to "true" for arbiter topology
- `arbiter_memory`: Memory for arbiter node in MB (default: 16384)

### Deployment Options

- `kcli_threaded`: Enable threaded deployment (default: true)
- `kcli_async`: Enable async deployment (default: false)
- `kcli_debug`: Enable kcli debug output (default: false)
- `force_cleanup`: Remove existing cluster before deployment (default: false)


## Usage

### Interactive Mode (Default)

1. Install required Ansible collections:
```bash
ansible-galaxy collection install -r collections/requirements.yml
```

2. Download OpenShift pull secret and place in role files directory:
```bash
# Navigate to the kcli-install files directory
cd roles/kcli/kcli-install/files/

# Create pull secret file (paste your pull secret content)
cat > pull-secret.json << EOF
{"auths":{"your-pull-secret-content-here"}}
EOF
```
   - For CI builds: Ensure pull secret includes `registry.ci.openshift.org` access

3. Run the playbook (will prompt for topology and automatically install prerequisites):
```bash
ansible-playbook kcli-install.yml -i inventory.ini
```

4. Access the deployed cluster:
```bash
export KUBECONFIG=~/.kcli/clusters/edge-cluster-01/auth/kubeconfig
oc get nodes

# Or use proxy environment for remote access:
source ./proxy.env
oc get nodes
```

### Non-Interactive Mode

For automation, install collections and specify topology with disabled interactive mode:

```bash
# Install collections
ansible-galaxy collection install -r collections/requirements.yml

# Deploy fencing cluster
ansible-playbook kcli-install.yml \
  -e "topology=fencing" \
  -e "interactive_mode=false"

# Deploy arbiter cluster  
ansible-playbook kcli-install.yml \
  -e "topology=arbiter" \
  -e "interactive_mode=false"
```

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