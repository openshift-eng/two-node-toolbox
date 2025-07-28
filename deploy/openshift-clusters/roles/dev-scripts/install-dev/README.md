# Install-Dev Role

This role manages OpenShift development environment installation and configuration.

## Description

The install-dev role handles the complete setup of OpenShift bare metal development environments using dev-scripts. It:

1. Sets up and configures dev-scripts environment
2. Configures bash aliases for OpenShift CLI operations
3. Sets up proxy configuration for network access
4. Supports any cluster topology supported by dev-scripts that can be defined in the config.sh files

## Requirements

- dev-scripts repository and dependencies
- Network access for OpenShift deployment
- Bash shell for alias configuration

## Role Variables

### Default Variables (defaults/main.yml)

- `dev_scripts_path`: Path to dev-scripts directory (default: "openshift-metal3/dev-scripts")
- `dev_scripts_branch`: Git branch to use (default: "master")
- `test_cluster_name`: OpenShift cluster name (default: "ostest")
- `method`: Deployment method (default: "ipi")

### Computed Variables (vars/main.yml)

- `kubeconfig_path`: Path to cluster kubeconfig file
- `config_file`: Configuration script based on deployment mode
- `make_target`: Make target for deployment method

## Usage

This role is used as part of the main setup playbook:

```bash
ansible-playbook setup.yml
```

## Task Structure

- `dev-scripts.yml`: Dev-scripts environment setup
- `create.yml`: OpenShift cluster creation (conditional)
- `proxy.yml`: Proxy configuration setup
- `main.yml`: Orchestrates all tasks and configures aliases

## Notes

- **Alias Configuration**: Adds useful OpenShift CLI aliases to bash environment
- **Proxy Support**: Includes proxy configuration for network-restricted environments
