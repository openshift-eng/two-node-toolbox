# AWS Hypervisor Scripts

This directory contains scripts for managing EC2 instances used as hypervisors for OpenShift development.

## Configuration

### Environment Setup
Copy the `config/instance.env.template` file at the repository root to `config/instance.env` and set all variables to valid values for your user. The Makefile syncs it to `instance.env` in this directory before deploy and cluster targets; run `make sync-config` explicitly when invoking scripts directly.

```bash
# From the repository root
cp config/instance.env.template config/instance.env
# Edit config/instance.env with your specific values
```

Editing `instance.env` in this directory directly still works as before.

#### Automated RHSM Registration (Hands-off Deployment)
For a completely automated deployment without manual intervention, you can configure Red Hat Subscription Manager (RHSM) activation key variables in your `instance.env` file:

```bash
# Uncomment and set these variables for automated RHSM registration
export RHSM_ACTIVATION_KEY="your-activation-key-here"
export RHSM_ORG="your-org-id-here"
```

To obtain your activation key and organization ID, refer to Red Hat documentation: https://access.redhat.com/solutions/3341191

When these variables are properly configured, the system will automatically register with RHSM during initialization, eliminating the need for manual registration steps.

### Verifying Environment
To verify your environment is setup properly, source the instance.env and ensure it doesn't throw errors:
```bash
source ./instance.env
```

## Scripts

### Instance Lifecycle Scripts

#### `create.sh`
Creates a new EC2 instance using CloudFormation. Reads configuration from `instance.env`.

```bash
./scripts/create.sh
```

#### `init.sh`
Initializes a deployed instance by uploading necessary files and running initial setup.

```bash
./scripts/init.sh
```

#### `start.sh`
Starts a stopped EC2 instance and performs necessary post-startup checks.

```bash
./scripts/start.sh
```

`make start` retries only `InsufficientInstanceCapacity`: three total attempts,
60 seconds apart, in addition to AWS CLI internal retries. Other errors fail
immediately.

After exhaustion, retry later or consider another zone/region for a new deployment.

#### `stop.sh`
Stops a running EC2 instance with interactive cluster management options. The script will:
- Detect if OpenShift clusters are running
- Offer options for graceful cluster shutdown or cleanup
- Safely stop the instance based on user selection

```bash
./scripts/stop.sh
```

#### `destroy.sh`
Completely destroys the EC2 instance and all associated CloudFormation resources.

```bash
./scripts/destroy.sh
```

### Utility Scripts

#### `ssh.sh`
Establishes SSH connection to the EC2 instance using the configured key and user.

```bash
./scripts/ssh.sh
```

#### Instance status
Instance information (stack, IP address, SSH user, Cockpit URL) is included in the
status dashboard, together with live instance state and cluster health:

```bash
# From the deploy/ directory
make status
```

#### `inventory.sh`
Updates the `../openshift-clusters/inventory.ini` file with the current instance IP address.

```bash
./scripts/inventory.sh
```

### Instance Configuration Script

#### `configure.sh`
This script is deployed to the EC2 instance during initialization and should be run after first login to complete the setup.

**Location on instance:** `~/configure.sh`

**Interactive Configuration:**
If RHSM variables are not configured, you will be asked to:
- Set a password for pitadmin (cockpit access)
- Register the system using your RHSM login for dnf access to various repositories

**Automated Configuration:**
If you have configured the RHSM activation key variables in your `instance.env` file, the system registration will be handled automatically, requiring only the pitadmin password configuration.

```bash
# Run on the EC2 instance after first login
[ec2-user@ip-x-x-x-x ~]$ ./configure.sh
```

## Graviton (aarch64) Instances

This toolbox supports AWS Graviton bare metal instances (`c7g.metal`, `m7g.metal`, `r7g.metal`) as hypervisors. Graviton instances are ~40% cheaper than equivalent x86_64 instances (e.g., `c7g.metal` at $2.32/hr vs `c5n.metal` at $3.89/hr).

### Configuration

In your `instance.env`, set:

```bash
export RHEL_HOST_ARCHITECTURE=aarch64
export EC2_INSTANCE_TYPE="c7g.metal"  # or m7g.metal, r7g.metal
```

AMI auto-detection works for both architectures — the `aarch64` → `arm64` mapping is handled automatically.

### Metal3 Image Overrides

Upstream Metal3 images (`quay.io/metal3-io/{ironic,vbmc,sushy-tools}`) are x86_64-only. On aarch64 hypervisors, you must override them with arm64 builds in your dev-scripts config (e.g., `config_fencing.sh`):

```bash
if [ "$(uname -m)" = "aarch64" ]; then
    export IRONIC_IMAGE=quay.io/rh-edge-enablement/ironic:2026-06
    export VBMC_IMAGE=quay.io/rh-edge-enablement/vbmc:2026-06
    export SUSHY_TOOLS_IMAGE=quay.io/rh-edge-enablement/sushy-tools:2026-06
fi
```

See `config/config_fencing_example.sh` at the repository root for a complete example. To rebuild these images, use `helpers/build-metal3-arm64.sh` (see [helpers/README.md](../../helpers/README.md)).

### Known Limitations

- **IPv6 IPI is not supported on aarch64** — nodes enter `inspecting` but never PXE-boot the IPA ramdisk. Use `IP_STACK=v4`.
- **CI release auto-discovery does not work** — you must set `OPENSHIFT_RELEASE_IMAGE` explicitly to an aarch64 payload (e.g., `quay.io/openshift-release-dev/ocp-release:4.22.0-aarch64`).

## Script Dependencies

All scripts expect:
- Properly configured `instance.env` file
- AWS CLI configured with appropriate credentials
- SSH key file accessible at the path specified in `instance.env`

## Data Storage

Instance metadata is stored in the `instance-data/` directory:
- `aws-instance-id`: EC2 instance ID
- `private_address`: Instance private IP
- `public_address`: Instance public IP
- `ssh_user`: SSH username for the instance
- Additional CloudFormation and configuration data
