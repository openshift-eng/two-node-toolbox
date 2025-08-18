# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

Two-Node Toolbox (TNF) is a comprehensive deployment automation framework for OpenShift two-node clusters in development and testing environments. The project supports multiple deployment methods and virtualization platforms, with a focus on "Two-Node with Arbiter" and "Two-Node with Fencing" topologies.

## Common Commands

### Deployment Operations
```bash
# From the deploy/ directory:

# Deploy AWS hypervisor and cluster in one command
make deploy arbiter-ipi   # Deploy arbiter topology cluster 
make deploy fencing-ipi   # Deploy fencing topology cluster

# Instance lifecycle management
make create              # Create new EC2 instance
make init               # Initialize deployed instance
make start              # Start stopped EC2 instance
make stop               # Stop running EC2 instance
make destroy            # Destroy EC2 instance and resources

# Cluster operations
make redeploy-cluster   # Redeploy OpenShift cluster using dev-scripts
make shutdown-cluster   # Shutdown cluster VMs
make startup-cluster    # Start cluster VMs and proxy
make clean             # Clean OpenShift cluster
make full-clean        # Complete cleanup including cache

# Utilities
make ssh               # SSH into EC2 instance
make info              # Display instance information
make inventory         # Update inventory.ini with current instance IP
```

### Ansible Deployment Methods

#### Dev-scripts Method (Traditional)
```bash
# Install required collections
ansible-galaxy collection install -r collections/requirements.yml

# Interactive deployment (prompts for topology)
ansible-playbook setup.yml -i inventory.ini

# Non-interactive deployment
ansible-playbook setup.yml -e "topology=arbiter" -e "interactive_mode=false" -i inventory.ini
ansible-playbook setup.yml -e "topology=fencing" -e "interactive_mode=false" -i inventory.ini

# Redfish stonith configuration (for fencing topology)
ansible-playbook redfish.yml -i inventory.ini

# Cleanup
ansible-playbook clean.yml -i inventory.ini
```

#### Kcli Method (Alternative)
```bash
# Deploy fencing cluster (default topology for kcli)
ansible-playbook kcli-install.yml -i inventory.ini

# Custom cluster configuration
ansible-playbook kcli-install.yml -i inventory.ini -e "test_cluster_name=my-cluster"

# Force cleanup and redeploy
ansible-playbook kcli-install.yml -i inventory.ini -e "force_cleanup=true"
```

### Linting and Validation
```bash
# Shell script linting (from repository root)
make shellcheck
# or manually:
./hack/shellcheck.sh
```

## Architecture and Structure

### Core Components

1. **AWS Hypervisor Management** (`deploy/aws-hypervisor/`)
   - Go-based CloudFormation automation for RHEL hypervisor deployment
   - Instance lifecycle scripts for create/start/stop/destroy operations
   - Automatic inventory management for Ansible integration

2. **OpenShift Cluster Deployment** (`deploy/openshift-clusters/`)
   - Two deployment methods: dev-scripts (traditional) and kcli (modern)
   - Ansible roles for complete cluster automation
   - Support for both arbiter and fencing topologies
   - Proxy configuration for external cluster access

3. **Ansible Roles Architecture**:
   - `dev-scripts/install-dev`: Traditional deployment using openshift-metal3/dev-scripts
   - `kcli/kcli-install`: Modern deployment using kcli virtualization management
   - `proxy-setup`: Squid proxy for cluster external access
   - `redfish`: Automated stonith configuration for fencing topology
   - `config`: SSH key and git configuration
   - `git-user`: Git user configuration for development

### Deployment Topologies

- **Two-Node with Arbiter (TNA)**: Master nodes + separate arbiter node for quorum
- **Two-Node with Fencing (TNF)**: Master nodes with BMC-based fencing for high availability

### Key Configuration Files

#### Dev-scripts Method
- `inventory.ini`: Ansible inventory (copy from `inventory.ini.sample`)
- `roles/dev-scripts/install-dev/files/config_arbiter.sh`: Arbiter topology config
- `roles/dev-scripts/install-dev/files/config_fencing.sh`: Fencing topology config  
- `roles/dev-scripts/install-dev/files/pull-secret.json`: OpenShift pull secret

#### Kcli Method
- `vars/kcli-install.yml`: Variable override file for persistent configuration
- `roles/kcli/kcli-install/files/pull-secret.json`: OpenShift pull secret
- SSH key automatically read from `~/.ssh/id_ed25519.pub` on ansible controller

#### Generated Files
- `proxy.env`: Generated proxy configuration (source this to access cluster)
- `kubeconfig`: OpenShift cluster kubeconfig
- `kubeadmin-password`: Default admin password

### Development Workflow

1. **Environment Setup**: Use `deploy/aws-hypervisor/` tools or bring your own RHEL 9 host
2. **Configuration**: Edit inventory and config files based on chosen deployment method
3. **Deployment**: Run appropriate Ansible playbook (setup.yml or kcli-install.yml)
4. **Access**: Source `proxy.env` and use `oc` commands or WebUI through proxy
5. **Cleanup**: Use cleanup make targets or Ansible playbooks

### Integration Points

- **External Dependencies**: Requires access to Red Hat container registries and CI registries
- **Virtualization**: Integrates with libvirt/KVM on target hypervisor
- **Cloud Integration**: AWS CloudFormation for automated hypervisor provisioning
- **Networking**: Configures libvirt networking and external proxy for cluster access

### Important Constraints

- **Target Host Requirements**: RHEL 9 or compatible, 64GB+ RAM, d_type filesystem support
- **Network Access**: Requires internet access for image downloads and registry access
- **CI Token**: Required for CI builds (get from https://console-openshift-console.apps.ci.l2s4.p1.openshiftapps.com)
- **Pull Secret**: Must include access to required registries, especially for CI builds

The repository includes comprehensive README files in `deploy/openshift-clusters/` for detailed setup instructions and troubleshooting guidance for both deployment methods.

## Development Guidelines and Standards

### Critical Repository Structure Rules

**IMPORTANT**: The `kcli/` directory is included for reference only and should NEVER be modified. It contains the upstream kcli tool that we integrate with, but all development work happens in the `deploy/` and `docs/` directories.

### File Organization

**Development Areas:**
- **`deploy/`**: All deployment automation and infrastructure code
  - `deploy/aws-hypervisor/`: AWS hypervisor setup scripts  
  - `deploy/openshift-clusters/`: OpenShift cluster deployment with Ansible
- **`docs/`**: Project documentation for different topologies
- **`kcli/`**: **READ-ONLY** - Reference copy of upstream kcli tool (DO NOT MODIFY)

### Coding Standards

#### Python Code (when needed)
- Follow PEP 8 style guidelines
- Use meaningful variable and function names
- Include docstrings for modules, classes, and functions
- Prefer explicit imports over wildcard imports
- Use f-strings for string formatting when possible
- Handle exceptions appropriately with specific exception types

#### YAML Configuration  
- Use 2-space indentation for YAML files
- Quote strings when they contain special characters
- Use descriptive keys and maintain consistent structure
- Comment complex configurations

#### Shell Scripts
- Use `#!/usr/bin/bash` shebang
- Include error handling with `set -euo pipefail`
- Use meaningful variable names in UPPER_CASE
- Add comments for complex logic
- Quote variables properly to prevent word splitting

### Security and Best Practices

- Handle secrets and credentials securely
- Use service accounts where possible
- Implement least privilege access
- Support air-gapped environments
- Never include sensitive information (API keys, tokens) in code or commits
- Use environment variables for sensitive data
- Validate configuration early and fail fast

### OpenShift/Kubernetes Specific Guidelines

#### Cluster Management
- Support both SNO (Single Node OpenShift) and two-node topologies
- Handle cluster lifecycle operations (create, scale, delete)
- Implement proper resource cleanup
- Support both connected and disconnected deployments

#### Infrastructure Code
- Use Infrastructure as Code principles
- Make deployments idempotent
- Support different infrastructure providers
- Include resource tagging and labeling

### Development Workflow Rules

#### When Making Changes
- **NEVER modify anything in the `kcli/` directory** - it's reference material only
- Focus changes on `deploy/` scripts and `docs/` documentation
- Consider impact on multiple virtualization providers when updating deployment scripts
- Test deployment scenarios end-to-end
- Update relevant documentation in `docs/` and README files
- Consider backward compatibility for existing deployments
- Check for credential exposure in logs or output
- Validate Ansible playbooks and shell scripts before committing

#### Working with kcli Integration
- Use `kcli/` directory as reference for understanding kcli capabilities
- Study `kcli/kvirt/providers/` to understand provider implementations
- Reference `kcli/kvirt/cluster/openshift/` for OpenShift deployment patterns
- Check `kcli/samples/` for configuration examples
- **Remember**: Read from kcli for understanding, implement in `deploy/` for our use

### Dependencies and Configuration

#### Dependencies
- Minimize external dependencies
- Use virtual environments for Python development
- Pin dependency versions in production configurations
- Separate optional dependencies by provider (AWS, GCP, etc.)

#### Error Handling
- Provide meaningful error messages
- Include context about what operation failed
- Log important events and errors appropriately
- Gracefully handle provider-specific failures

### Testing Guidelines

- Write tests for new functionality
- Test against multiple virtualization providers when applicable
- Include integration tests for deployment scenarios
- Document test requirements and setup

### Documentation Standards

- READMEs should be technical and concise (no emojis or marketing language)
- Include prerequisites, setup instructions, and usage examples
- Document configuration options and environment variables
- Maintain consistency across all documentation

### Git and Commit Practices

- Use conventional commit messages
- Keep commits focused and atomic
- Include issue references in commit messages
- Update documentation with code changes