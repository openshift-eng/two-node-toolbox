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
- `method`: Deployment method (set by calling playbook, e.g., "ipi")
- `install_dev_start_async`: Max seconds for the Start OpenShift task (default: `14400` / 4h). Applies to both IPI and agent installs. Override with `-e install_dev_start_async=...` if needed.
- `install_dev_start_poll`: Seconds between async status polls (default: `60`). Must be `>= 1`; `0` would fire-and-forget and hide make failures.

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

- `main.yml`: Orchestrates all tasks and configures aliases
- `bounce.yml`: Cluster bounce/restart operations
- `check_vars.yml`: Variable validation
- `config.yml`: Configuration setup
- `teardown.yml`: Cluster teardown operations

## Notes

- **Alias Configuration**: Adds useful OpenShift CLI aliases to bash environment
- **Proxy Support**: Includes proxy configuration for network-restricted environments
