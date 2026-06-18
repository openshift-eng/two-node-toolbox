# Helpers

Utilities for OpenShift cluster operations including package management and cluster validation.

## Description

This directory contains multiple helper tools for various OpenShift cluster operations:

- **Resource Agent Patching**: Scripts and playbooks (recommended usage) for installing RPM packages on cluster nodes using rpm-ostree's override functionality
- **Fencing Validation**: Tools for validating two-node cluster fencing configuration and health
- **Custom OCP 5.x payload (optional)**: `resource-agents-build/custom-payload.sh` to build a custom RHCOS layer from the resource-agents RPM and publish a custom release image with `oc adm release new`

## Requirements

### For build-and-patch-resource-agents.yml and apply-rpm-patch.yml 
- Ansible playbooks. See below for specific prerequisites for each

### For apply-rpm-patch.sh
- `oc` CLI tool (logged into OpenShift cluster)
- `jq` for JSON processing
- SSH access to cluster nodes

### For fencing_validator.sh
- `oc` CLI tool (logged into OpenShift cluster)
- For SSH transport: passwordless sudo access to cluster nodes
- Two-node cluster with fencing topology

## Available Tools

### Force New Cluster

Automates etcd cluster recovery by configuring CIB (Cluster Information Base) attributes to force a new etcd cluster formation. This is useful when etcd quorum is lost and manual intervention is required to restore cluster functionality.

**Features:**
- Automated etcd snapshot creation before recovery operations
- CIB attribute management for force-new-cluster operations
- Leader/follower node detection and verification
- Etcd member list management
- Automatic cleanup and resource recovery
- STONITH management during operations

**Usage:**

```bash
# From helpers/ directory
ansible-playbook -i ../deploy/openshift-clusters/inventory.ini force-new-cluster.yml
```

**Prerequisites:**
- Inventory file with exactly 2 nodes in `cluster_vms` group
- SSH access to cluster VMs with sudo privileges
- Running Pacemaker cluster with etcd resources

**What it does:**
1. Validates cluster has exactly 2 nodes
2. Disables STONITH temporarily for safety
3. Takes etcd snapshots on both nodes (if etcd is not running)
4. Clears existing CIB attributes (learner_node, standalone_node, force_new_cluster)
5. Sets force_new_cluster attribute on the leader node (first node in cluster_vms)
6. Verifies CIB attributes on both nodes
7. Removes follower from etcd member list
8. Performs pcs resource cleanup on both nodes
9. Re-enables STONITH after completion

**Attribution:** Original shell script by Carlo Lobrano

### Log Collection

Collects etcd related logs from cluster VMs

**Usage:**

*From deploy/ directory (recommended):*
```bash
make get-tnf-logs
```

*Using Ansible directly:*
```bash
# From helpers/ directory
ansible-playbook -i ../deploy/openshift-clusters/inventory.ini collect-tnf-logs.yml
```

**Prerequisites:**
- Inventory file with `cluster_vms` group
- SSH access to cluster VMs via ProxyJump
- `oc` CLI tool on cluster nodes

### Fencing Validator

Validates fencing configuration and health for two-node OpenShift clusters with STONITH-enabled Pacemaker.

**Features:**
- Non-disruptive validation (default): Checks STONITH presence/enabled status, node health, etcd quorum, and daemon status
- Disruptive testing: Performs actual fencing of both nodes to verify recovery (optional with `--disruptive`)
- Multiple transport methods: Auto-detection, SSH, or oc debug
- IPv4/IPv6 support with automatic node discovery



**Usage:**

*From outside the hypervisor (uses oc debug transport by default):*
```bash
# Non-disruptive validation (recommended)
./fencing_validator.sh

# With custom hosts
./fencing_validator.sh --hosts "10.0.0.10,10.0.0.11"
```

*From inside the hypervisor via ansible (requires hypervisor deployed via `make deploy`):*
```bash
# Copy script to hypervisor and execute remotely
ansible all -i deploy/openshift-clusters/inventory.ini -m copy -a "src=helpers/fencing_validator.sh dest=~/fencing_validator.sh mode=0755"
ansible all -i deploy/openshift-clusters/inventory.ini -m shell -a "./fencing_validator.sh"
```

*Disruptive testing options:*
```bash
# Disruptive testing (NOTE: Not yet supported - under development)
./fencing_validator.sh --disruptive

# Dry run to see what would be tested
./fencing_validator.sh --disruptive --dry-run
```

**Note:** Disruptive testing functionality is not yet fully supported and should not be used in production environments.


### MAC-Only Fencing Credentials (dev-scripts patch)

Patches dev-scripts on a hypervisor to generate `macaddress:`-based fencing credentials instead of `hostname:`-based ones in the ABI install-config. Used for verifying [OCPEDGE-2692](https://issues.redhat.com/browse/OCPEDGE-2692) (MAC address fencing credential support in assisted-service).

**What it patches** (4 files under `dev-scripts/`):
1. `config_*.sh` — ensures `AGENT_E2E_TEST_SCENARIO="TNF_IPV4"` is set; fixes `OPENSHIFT_CI` case sensitivity (`"TRUE"` → `"true"`)
2. `agent/05_agent_configure.sh` — collects master MAC addresses into `AGENT_MASTER_MACS_STR`
3. `agent/roles/manifests/vars/main.yml` — adds `agent_master_macs` Ansible variable
4. `agent/roles/manifests/templates/install-config_baremetal_yaml.j2` — replaces `hostname:` with `macaddress:` in the fencing credentials block

**Prerequisites:**
- Hypervisor must be initialized (TNT `make init` or `make deploy`) so that dev-scripts is already cloned
- A running cluster is NOT required — this patches source files before deployment

**Usage:**

```bash
# From helpers/ directory — auto-discovers hypervisor from TNT inventory
./patch-devscripts-mac-fencing.sh

# Or specify an explicit hypervisor
./patch-devscripts-mac-fencing.sh ec2-user@<hypervisor-ip>

# Then on the hypervisor:
cd /home/ec2-user/openshift-metal3/dev-scripts
sudo make agent
```

The hypervisor is auto-discovered from `deploy/openshift-clusters/inventory.ini` (the `[metal_machine]` group). An explicit argument overrides auto-discovery.

**Important:** TNT's Ansible role runs `git checkout --force` on dev-scripts before every deployment, wiping these patches. Either run this script after TNT's git checkout (before `make agent`), or deploy directly on the hypervisor.

### Resource Agents Patching

The `build-and-patch-resource-agents.yml` playbook automates the entire workflow:
1. Builds the resource-agents RPM on the hypervisor
2. Copies the RPM back to your laptop
3. Automatically calls `apply-rpm-patch.yml` to patch cluster nodes

#### Usage

```bash
# From the deploy/ directory
# Simplest, no customization. Uses resource-agents repo, main branch, auto sets next version
make patch-nodes
```

#### Using Ansible Directly

```bash
# From the helpers/ directory

# Use defaults (ClusterLabs repo, main branch, version 4.11)
ansible-playbook -i ../deploy/openshift-clusters/inventory.ini \
  build-and-patch-resource-agents.yml

# Specify custom version
ansible-playbook -i ../deploy/openshift-clusters/inventory.ini \
  build-and-patch-resource-agents.yml \
  -e rpm_version=4.12

# Use custom repository and branch
ansible-playbook -i ../deploy/openshift-clusters/inventory.ini \
  build-and-patch-resource-agents.yml \
  -e repo_url=https://github.com/myorg/resource-agents \
  -e rpm_branch=my-feature-branch \
  -e rpm_version=5.0
```

**Prerequisites:**
- Inventory file at `../deploy/openshift-clusters/inventory.ini` with both `metal_machine` and `cluster_vms` groups
- SSH access to hypervisor (metal_machine)
- ProxyJump SSH configuration for cluster VMs (automatically configured by setup.yml)

**What it does:**
1. Validates inventory contains both `[metal_machine]` and `[cluster_vms]` groups
2. Installs build dependencies on hypervisor
3. Clones resource-agents repository on hypervisor
4. Builds RPM using `make rpm VERSION=<version>`
5. Fetches RPM back to helpers/ directory
6. Automatically patches cluster_vms group with the new RPM
7. Reboots cluster nodes one at a time with etcd health verification

**Variables:**
- `repo_url`: Git repository URL (default: `https://github.com/ClusterLabs/resource-agents`)
- `rpm_branch`: Git branch to checkout (default: `main`)
- `rpm_version`: Version string for the RPM (default: `4.11`)

### apply-rpm-patch.yml playbook

If the RPM to be installed is already available to you, this Ansible playbook provides automated installation and rebooting with proper orchestration.

#### Option 1: From Your Laptop

Use with the automatically-generated inventory from the openshift-clusters deployment:

```bash
# Target the cluster_vms group
ansible-playbook -i /path/to/inventory.ini \
  apply-rpm-patch.yml \
  -l cluster_vms \
  -e rpm_full_path=/absolute/path/to/package.rpm
```

**Prerequisites:**
- Inventory with `cluster_vms` group (created automatically by update-cluster-inventory.yml task)
- ProxyJump SSH configuration through hypervisor (automatically configured in inventory)
- Absolute path to RPM file on your laptop

**Process:**
1. Validates RPM file exists on localhost
2. Copies RPM to cluster VMs via ProxyJump
3. Installs using rpm-ostree override with privilege escalation
4. Reboots nodes one at a time
5. Verifies etcd health after reboot

#### Option 2: From the Hypervisor

Use with a custom inventory directly on the hypervisor:

```bash
# On the hypervisor, create a simple inventory file first
# See inventory_ocp_hosts.sample for reference
ansible-playbook -i inventory_ocp_hosts \
  apply-rpm-patch.yml \
  -e rpm_full_path=/path/to/package.rpm
```

**Prerequisites:**
- Copy RPM file and apply-rpm-patch.yml playbook to hypervisor
- Create inventory file listing cluster VM IPs (see `inventory_ocp_hosts.sample`)

**Process:**
1. Validates RPM file existence
2. Copies RPM to all nodes
3. Installs using rpm-ostree override with privilege escalation
4. Reboots nodes one at a time
5. Verifies etcd health after reboot

### apply-rpm-patch.sh (not recommended)

If you don't want or are unable to use the previous Ansible playbooks, you can use this shell script .It should be inoked from within the hypervisor, as it requires direct access to the nodes via SSH and assumes the "core" user.

#### Usage

```bash
./apply-rpm-patch.sh /path/to/package.rpm
```

**Process:**
1. Validates required tools and RPM file
2. Discovers all node IPs via OpenShift API
3. Copies RPM to each node using SCP
4. Installs package with `rpm-ostree override replace`
5. Provides manual reboot commands

**Note:** The shell script does not handle reboots automatically. You must manually reboot nodes after installation. Follow the instructions provided at the end of the script execution

### Containerized Build Validation

The `resource-agents-build/` directory contains Dockerfiles and a script for validating that resource-agents compiles correctly on CentOS Stream 9 and 10, without needing a hypervisor or cluster. This is useful for quickly verifying a branch builds before running the full `build-and-patch-resource-agents.yml` playbook.

**Usage:**

```bash
cd helpers/resource-agents-build

# Run both builds — prompts for repo and ref, press Enter to use defaults
./local-build-test.sh

# Skip prompts by providing values via flags
./local-build-test.sh --repo https://github.com/myorg/resource-agents --ref my-feature-branch

# Build individually with podman
podman build -f Dockerfile.stream9 -t localhost/tnf-resource-agents-build:stream9 .
podman build -f Dockerfile.stream10 -t localhost/tnf-resource-agents-build:stream10 .
```

**Script options:**

| Option | Description |
|--------|-------------|
| `--repo URL` | Git repository URL (default: `https://github.com/ClusterLabs/resource-agents`) |
| `--ref REF` | Git branch, tag, or commit (default: `main`) |
| `-h`, `--help` | Show help |

When no flags are provided, the script prompts for each value. Press Enter to use the default.

**Extracting the built RPM from the container** (Stream 9 only — Stream 10 skips `make rpm`):

```bash
# Build from a specific branch
./local-build-test.sh --ref my-feature-branch

# Copy the RPM out of the Stream 9 image
podman create --name ra-build localhost/tnf-resource-agents-build:stream9
podman cp ra-build:/tmp/resource-agents.rpm ./resource-agents.rpm
podman rm ra-build

# Then patch your cluster nodes with it
ansible-playbook -i ../../deploy/openshift-clusters/inventory.ini \
  ../apply-rpm-patch.yml \
  -l cluster_vms \
  -e rpm_full_path=$(pwd)/resource-agents.rpm
```

This is useful when you want to validate the RPM locally before patching.

**Stream 10 limitation:** `libqb-devel` is not yet available in EPEL 10. The Dockerfile builds libqb from source for `configure`/`make` validation, but skips `make rpm` since rpmbuild's `BuildRequires: libqb-devel` cannot be satisfied without the actual RPM package.

### custom-payload.sh

`custom-payload.sh` ties the containerized build to an OpenShift 5.x release: it resolves a nightly payload, prints the base `rhel-coreos` / `rhel-coreos-10` image from `oc adm release info`, and generates `Dockerfile.custompayload` by combining the **contents** of `Dockerfile.stream9` or `Dockerfile.stream10` (depending on `--base-os`) with an RPM-ostree override snippet—the script does **not** change `Dockerfile.stream9` or `Dockerfile.stream10` on disk. Then, unless you use **dry-run-style** flags, it runs `podman` to build and push the custom OS image and runs `oc adm release new` to publish a custom **release payload** image that points that OS layer at the correct component name (for example `rhel-coreos-10=...`).

**When to use it:** after you are happy with a resource-agents RPM from `local-build-test.sh` (or an equivalent build), and you want a full custom payload image to install or test on a 5.0 line cluster—without going through the hypervisor-based `build-and-patch-resource-agents.yml` path for node RPM overrides alone.

**Requirements:** `curl`, `oc`, `podman`, and `jq` or `python3` (for `--auto-release`). Pull secret handling works the same way as other `oc` / `podman` registry operations (`-a` / `PULL_SECRET_PATH`, or the default `~/.docker/config.json` / `~/.config/containers/auth.json` as documented in the script's `--help`).

**Usage (from `helpers/resource-agents-build/`):**

```bash
cd helpers/resource-agents-build

# Use the newest Accepted 5.0.0-0.nightly tag from the release API
./custom-payload.sh --auto-release

# Or pin a full release pullspec
./custom-payload.sh --release registry.ci.openshift.org/ocp/release-5:5.0.0-0.nightly-...

# Explicit pull secret (optional if a default auth file exists)
./custom-payload.sh --auto-release -a /path/to/pull-secret

# Only print Dockerfile and commands; do not run oc / skip real builds (see --help)
./custom-payload.sh --auto-release --print-only
./custom-payload.sh --auto-release --no-build
```

Run `./custom-payload.sh --help` for flags such as `--base-os` (`rhel-coreos` vs `rhel-coreos-10`), `--to-os-image`, and `--to-payload-image` (custom registry targets and tags).

**Pull secret and the same registry twice:** if you use different tokens on the same registry host—for example one credential for the general `quay.io` pull path and another for a specific org such as `quay.io/rh-edge-enablement`—put them in **separate** `auths` entries, for example one key `quay.io` and another `quay.io/rh-edge-enablement`. A single `quay.io` entry may not match both paths reliably; splitting them keeps pulls and pushes unambiguous for `oc` and `podman`.

ex:
```json
{
        "auths": {
           ....
                "quay.io": {
                        "auth": "<secret>"
                },
                "quay.io/eggfoobar": {
                        "auth": "<secret_same>"
                },
                "quay.io/rh-edge-enablement": {
                        "auth": "<secret_same>"
                },
           ....
        }
}
```

## Notes

- Both tools use `rpm-ostree override replace` which is appropriate for updating existing packages
- Node reboots are required to activate rpm-ostree changes
- The Ansible playbooks handle rebooting automatically with proper orchestration; the shell script requires manual intervention
- Plan reboots carefully to maintain cluster availability
- Monitor cluster health during the patching process 