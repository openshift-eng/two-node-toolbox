# Clean Role

This role cleans up OpenShift deployments and resets the dev-scripts environment.

## Description

The clean role performs cleanup operations for OpenShift bare metal deployments managed by dev-scripts. It:

1. Stops the OpenShift cluster using the dev-scripts clean target (or realclean for complete removal, including downloaded images)
2. Resets the dev-scripts git checkout to the origin/master branch
3. Completely removes the `/opt/dev-scripts` directory and all its contents

## Requirements

- dev-scripts repository cloned and configured
- Make utility available
- Root/sudo privileges for directory removal

## Role Variables

### Default Variables (defaults/main.yml)

- `dev_scripts_path`: Path to the dev-scripts directory (default: "openshift-metal3/dev-scripts")
- `dev_scripts_branch`: Git branch to reset to (default: "master")
- `dev_scripts_src_repo`: Git repo to use (default: "https://github.com/openshift-metal3/dev-scripts")

### Optional Variables

- `complete`: Boolean flag to control cleanup level (default: false)
  - `false`: Uses `make clean` (standard cleanup)
  - `true`: Uses `make realclean` (complete cleanup including images and cached data)

## Usage

### Standard cleanup
This will delete and reset the cluster but keep all downloaded files, as well as other artifacts (like the proxy pod). Use it if you want to reinstall Openshift without a full cleanup.
```bash
ansible-playbook clean.yml
```

### Complete cleanup
This will also clean cache, workingdir (image downloads), podman and registry. Use for a complete reset of the underlying hypervisor
```bash
ansible-playbook clean.yml -e complete=true
```

Or set in inventory/vars:
```yaml
complete: true
```

## Notes

- **Validation**: The role validates that `dev_scripts_path` is defined before proceeding 