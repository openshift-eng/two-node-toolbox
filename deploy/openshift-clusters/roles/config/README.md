# Config Role

Common configuration and utility tasks shared across OpenShift deployment roles.

## Description

This role provides common functionality that can be reused by different OpenShift deployment methods (kcli, dev-scripts, etc.) to ensure consistency and reduce code duplication.

## Common Tasks

### cluster-state.yml

Manages cluster deployment state tracking across different installation methods.

**Usage:**
```yaml
- name: Set cluster state to deploying
  include_role:
    name: config
    tasks_from: cluster-state
  vars:
    cluster_state_phase: 'deploying'  # or 'deployed'
    installation_method: 'kcli'       # or 'ipi'
    default_playbook_name: 'setup.yml'
```

**Required Variables:**
- `cluster_state_phase`: 'deploying' or 'deployed'
- `installation_method`: Installation method identifier (e.g., 'kcli', 'ipi')
- `topology`: Cluster topology ('fencing' or 'arbiter')
- `cluster_state_dir`: Directory for state files
- `cluster_state_filename`: State file name

**Optional Variables:**
- `default_playbook_name`: Default playbook name for state tracking
- `num_masters` / `ctlplanes`: Number of master nodes
- `num_workers` / `workers`: Number of worker nodes
- `enable_arbiter`: Arbiter configuration

### validate-auth.yml

Validates authentication files required for OpenShift deployment.

**Usage:**
```yaml
- name: Validate authentication files
  include_role:
    name: config
    tasks_from: validate-auth
```

**Required Variables:**
- `pull_secret_path`: Path to OpenShift pull secret
- `ssh_public_key_path`: Path to SSH public key

**Optional Variables:**
- `ocp_version`: OpenShift version (enables CI registry validation when set to 'ci')

## Benefits

- **Consistency**: Ensures identical behavior across deployment methods
- **Maintainability**: Single source of truth for common functionality
- **Reliability**: Shared validation reduces deployment failures
- **Testability**: Common tasks only need testing once

## Integration

Both `kcli/kcli-install` and `dev-scripts/install-dev` roles use these common tasks to eliminate code duplication while maintaining consistent cluster state management and validation.

 