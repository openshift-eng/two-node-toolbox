# kcli-redfish Role

This role configures PCS (Pacemaker/Corosync) Stonith resources for kcli-deployed OpenShift clusters using simulated Redfish BMC endpoints.

## Description

The kcli-redfish role automates the configuration of STONITH (Shoot-The-Other-Node-In-The-Head) resources for kcli-deployed OpenShift clusters. Unlike bare metal deployments that use BareMetalHost resources, kcli deployments use virtual machines with simulated BMC functionality via [ksushy](https://kcli.readthedocs.io/en/latest/index.html#ksushy). For more information, see [the deploy folder README](../../../README.md#redfish-stonith-configuration)

This role:
1. Identifies cluster nodes from kcli deployment configuration
2. Creates ksushy systemd service on the hypervisor for SSL-enabled BMC simulation
3. Configures firewall rules to allow BMC access from VMs
4. Configures PCS stonith resources on each node using `fence_redfish`
5. Enables stonith in the cluster

## Requirements

- OpenShift cluster deployed with kcli fencing topology
- kcli command available on the hypervisor host
- `kubernetes.core` Ansible collection
- Python 3 with `kubernetes`, `PyYAML`, and `jsonpatch` libraries (automatically installed)
- `oc` CLI tool available in PATH
- Valid kubeconfig file with cluster-admin permissions
- SSH access to the kcli deployment host (hypervisor)
- Sudo privileges on the hypervisor for firewall configuration and Python package installation

## Automatic Setup

The role automatically handles:
- Installing required Python dependencies (`kubernetes`, `PyYAML`, `jsonpatch`)
- Creating ksushy systemd service using `kcli create sushy-service`
- Configuring firewall rules (port 9000/tcp in libvirt zone)
- SSL certificate management (self-signed certificates via kcli)
- BMC endpoint discovery for all cluster VMs

## Dependencies

- kubernetes.core collection: `ansible-galaxy collection install kubernetes.core`
- Python dependencies are automatically installed by the role (kubernetes, PyYAML, jsonpatch)

## Role Variables

### Automatic Configuration

The role automatically detects all required configuration from:

| Variable | Auto-Detection Source | Override Available |
|----------|----------------------|-------------------|
| `test_cluster_name` | `kcli list cluster` or kcli-install defaults | Yes |
| `ksushy_ip` | Ansible inventory host IP | Yes |
| `ksushy_port` | kcli-install role defaults (9000) | Yes |
| `bmc_user` | kcli-install role defaults ("admin") | Yes |
| `bmc_password` | kcli-install role defaults ("admin123") | Yes |

### Manual Override Variables (Optional)

Override only if auto-detection fails:

- `test_cluster_name`: Override detected cluster name
- `ksushy_ip`: Override detected hypervisor IP
- `ksushy_port`: Override BMC simulator port
- `bmc_user`: Override BMC username
- `bmc_password`: Override BMC password
- `ssl_insecure_param`: SSL verification parameter (default: "ssl_insecure=1")

## Usage

### Running the Role

This role should be run after a successful kcli deployment with fencing topology. **No configuration required** - everything is auto-detected:

```bash
# Ensure you're authenticated to your OpenShift cluster
oc whoami

# Run the kcli-redfish configuration (fully automatic)
ansible-playbook kcli-redfish.yml -i inventory.ini
```

### Integration with kcli-install

The role can be integrated into the kcli-install workflow by adding it as a post-deployment task. **No variables required** due to auto-detection:

```yaml
# In kcli-install.yml or custom playbook
- name: Configure kcli fencing
  include_role:
    name: kcli.kcli-redfish
  # All configuration is automatically detected from kcli-install defaults
  # and current deployment environment
```

## How It Works

1. **Node Discovery**: Identifies cluster nodes by querying the OpenShift API
2. **BMC Endpoint Calculation**: Constructs BMC endpoints using the ksushy simulator
3. **Stonith Configuration**: Configures fence_redfish resources for each node
4. **Stonith Enablement**: Enables stonith globally in the cluster

The role understands that in kcli deployments:
- Virtual machines are named `{cluster-name}-ctlplane-{index}`
- BMC simulation uses ksushy with predictable endpoints
- No BareMetalHost resources exist in the cluster

## Troubleshooting

### Common Issues

**No cluster nodes found:**
```bash
# Verify cluster access
oc get nodes
```

**ksushy not accessible:**
```bash
# Check ksushy systemd service is running on the hypervisor
systemctl --user status ksushy.service

# Test ksushy endpoint (uses HTTPS with self-signed cert)
curl -k https://{ksushy_ip}:{ksushy_port}/redfish/v1/
```

**Stonith configuration fails:**
```bash
# Check existing stonith resources
oc debug node/{node-name} -- chroot /host pcs stonith status
``` 