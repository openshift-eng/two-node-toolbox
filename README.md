# TWO-NODE TOOLBOX

## Introduction

This repository provides automation for deploying and managing two-node OpenShift clusters for development and testing. It supports "Two-Node with Arbiter" (TNA) and "Two-Node with Fencing" (TNF) topologies using either dev-scripts or kcli deployment methods.

## Quick Start

### Option 1: AWS Hypervisor (Automated)

If you have AWS access, use the automated workflow. Most lifecycle operations can be performed from the [deploy](deploy/) folder using `make`:

```bash
cd deploy/

# Create AWS hypervisor and deploy cluster in one command
make deploy arbiter-ipi    # Two-Node with Arbiter (IPI method)
make deploy arbiter-agent  # Two-Node with Arbiter (Agent method)
make deploy fencing-ipi    # Two-Node with Fencing (IPI method)

# Other useful commands
make ssh                   # SSH into hypervisor
make info                  # Display instance information
make clean                 # Clean OpenShift cluster
make get-tnf-logs          # Collect cluster logs from VMs
make patch-nodes           # Build and patch resource-agents RPM
make help                  # Show all available commands
```

See [deploy/README.md](deploy/README.md) for complete command reference and [deploy/aws-hypervisor/README.md](deploy/aws-hypervisor/README.md) for AWS setup instructions.

### Option 2: Bring Your Own Server

If you have an existing RHEL 9 server, initialize it and deploy a cluster:

```bash
cd deploy/openshift-clusters/

# One-time host initialization (configures RHEL, subscriptions, packages)
cp inventory.ini.sample inventory.ini
# Edit inventory.ini with your server details
ansible-playbook init-host.yml -i inventory.ini

# Deploy OpenShift cluster (choose one method)
ansible-playbook setup.yml -i inventory.ini        # dev-scripts (arbiter or fencing)
ansible-playbook kcli-install.yml -i inventory.ini # kcli (fencing only)
```

See [deploy/openshift-clusters/README-external-host.md](deploy/openshift-clusters/README-external-host.md) for detailed instructions.

## Deployment Methods

**dev-scripts**: Traditional method supporting both arbiter and fencing topologies with IPI and Agent-based installation options.
- Documentation: [deploy/openshift-clusters/README.md](deploy/openshift-clusters/README.md)

**kcli**: Modern method with simplified VM management, currently supports fencing topology.
- Documentation: [deploy/openshift-clusters/README-kcli.md](deploy/openshift-clusters/README-kcli.md)

## Available Topologies

**Two-Node with Arbiter (TNA)**: Two master nodes with a separate arbiter node for quorum. See [docs/arbiter/README.md](docs/arbiter/README.md)

**Two-Node with Fencing (TNF)**: Two master nodes with BMC-based fencing for automated node recovery. See [docs/fencing/README.md](docs/fencing/README.md)

## First-Time Setup Helper

If you're using [Claude Code](https://claude.ai/code), use the `/setup` command to get interactive help configuring the repository for first-time use. It will guide you through:
- Copying configuration files from templates
- Setting up credentials and authentication
- Installing required dependencies
- Validating your setup

Run `/setup` to begin, or `/setup <method>` to configure a specific deployment method (aws, external, kcli, dev-scripts).
## Helpers

The [helpers/](helpers/) directory contains utilities for cluster operations including resource-agents patching, fencing validation, and containerized build validation. To quickly verify a resource-agents branch compiles on CentOS Stream 9 and 10:

```bash
make test-resource-agents                          # prompts for repo and ref
make test-resource-agents ARGS="--ref my-branch"   # skip prompts
```

To test the built RPM on a live cluster, extract it from the Stream 9 image and patch your nodes:

```bash
# Extract the RPM from the container image
podman create --name ra-build localhost/tnf-resource-agents-build:stream9
podman cp ra-build:/tmp/resource-agents.rpm ./resource-agents.rpm
podman rm ra-build

# Patch cluster nodes with the extracted RPM
ansible-playbook -i deploy/openshift-clusters/inventory.ini \
  helpers/apply-rpm-patch.yml \
  -l cluster_vms \
  -e rpm_full_path=$(pwd)/resource-agents.rpm
```

Alternatively, `make patch-nodes` (from `deploy/`) clones the resource-agents repo on the EC2 hypervisor, builds the RPM there natively, and patches the cluster nodes — all in one step, without needing a local container build.

See [helpers/README.md](helpers/README.md) for full documentation.

## Troubleshooting with Claude Code

If you're using [Claude Code](https://claude.ai/code), it can help you troubleshoot etcd issues on two-node fencing clusters. Simply ask Claude to diagnose your etcd problems and it will automatically collect diagnostics, analyze the cluster state, and recommend remediation steps. See [.claude/commands/etcd/README.md](.claude/commands/etcd/README.md) for details.

