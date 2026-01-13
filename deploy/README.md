# Deploy

This directory contains deployment tools and scripts for setting up EC2 instances and OpenShift clusters for development purposes.

## Prerequisites

### AWS CLI
If you are using the EC2 hypervisor option you will need to have the AWS CLI configured and the `AWS_PROFILE` environment variable set.

For getting and configuring the CLI: https://docs.aws.amazon.com/cli/

You can check if you have the AWS CLI properly configured by running:

```bash
$ aws configure list
      Name                    Value             Type    Location
      ----                    -----             ----    --------
   profile            openshift-dev              env    ['AWS_PROFILE', 'AWS_DEFAULT_PROFILE']
access_key     ****************4SU3 shared-credentials-file    
secret_key     ****************z0DF shared-credentials-file    
    region                us-east-2      config-file    ~/.aws/config
```

### Dependencies
The following programs must be present in your local environment:
- make
- aws
- jq
- rsync
- golang
- ansible

Also:
- .ssh/config file must exist

#### Extra dependencies
For automatic Redfish Pacemaker configuration on 4.19, you also need:
- Python3 kubernetes library (https://pypi.org/project/kubernetes/)

Additionally, if you're using Mac OS, you might not have `timeout`, so you might also need to install coreutils, for example via brew:
`brew install coreutils`

## Configuration

Before deployment, configure your environment by setting up the `aws-hypervisor/instance.env` file. Copy `aws-hypervisor/instance.env.template` to `aws-hypervisor/instance.env` and set all variables to valid values for your user.

## Available Commands

To see all available commands, run:
```bash
$ make help
```

### Quick Start
```bash
# Create, initialize, and update inventory for a new EC2 instance
$ make deploy
```

This will create the instance, initialize it, and update the inventory in one command, placing you in a login shell for the EC2 instance.

### Multi-Deployment Support

The toolbox supports managing multiple parallel deployments, useful for QE testing and comparison scenarios (e.g., testing different RHEL versions or cluster topologies simultaneously).

#### Creating Multiple Deployments

Specify a `DEPLOYMENT_ID` parameter to create and manage separate deployments:

```bash
# Create first deployment
$ make deploy DEPLOYMENT_ID=dev1

# Create second deployment
$ make deploy DEPLOYMENT_ID=dev2

# List all deployments
$ make list-deployments
```

#### Managing Specific Deployments

All commands accept the `DEPLOYMENT_ID` parameter:

```bash
# SSH into specific deployment
$ make ssh DEPLOYMENT_ID=dev1

# Deploy cluster to specific deployment
$ make arbiter-ipi DEPLOYMENT_ID=dev1
$ make fencing-ipi DEPLOYMENT_ID=dev2

# Destroy specific deployment
$ make destroy DEPLOYMENT_ID=dev1
```

#### Accessing Cluster Credentials

Each deployment has its own directory with cluster credentials:

```bash
# Access first deployment's cluster
$ source openshift-clusters/deployments/dev1/proxy.env
$ export KUBECONFIG=openshift-clusters/deployments/dev1/kubeconfig
$ oc get nodes

# Switch to second deployment's cluster
$ source openshift-clusters/deployments/dev2/proxy.env
$ export KUBECONFIG=openshift-clusters/deployments/dev2/kubeconfig
$ oc get nodes
```

#### Important Notes

- Each deployment creates a separate EC2 instance (separate hypervisors)
- Default DEPLOYMENT_ID: `${USER}-dev` (maintains backward compatibility)
- State stored in `aws-hypervisor/instance-data-${DEPLOYMENT_ID}/`
- Cluster configs stored in `openshift-clusters/deployments/${DEPLOYMENT_ID}/`
- Proxy containers are deployment-specific: `external-squid-${DEPLOYMENT_ID}`

### Recommended Instance Reuse Workflow

For quickly reusing an existing instance with a fresh cluster deployment:

```bash
# Force stop the instance (bypasses cluster checks)
$ make force-stop

# Start the instance
$ make start  

# Deploy a fresh cluster
$ make redeploy-cluster
```

This sequence is the fastest way to reset and reuse an instance when cluster preservation is not needed.

### Basic Instance Operations
```bash
# Create new EC2 instance
$ make create

# Initialize deployed instance  
$ make init

# Update inventory.ini with current instance IP
$ make inventory

# SSH into the EC2 instance
$ make ssh

# Get instance info
$ make info

# Start a stopped instance
$ make start

# Stop a running instance (with cluster management options)
$ make stop

# Force stop instance immediately (no cluster checks)
$ make force-stop

# Completely destroy the instance
$ make destroy
```

### OpenShift Cluster Management

When running OpenShift clusters on the instance (using dev-scripts), you have several options for managing cluster lifecycle:

**Quick deployment commands:**
- `make fencing-ipi`, `make arbiter-ipi`, and `make arbiter-agent` provide non-interactive deployment for specific topologies
- These commands automatically call the underlying setup.yml playbook with the appropriate configuration
- Useful for automation and when you know exactly which topology you want to deploy

#### Option 1: Force Stop and Redeploy (Recommended for instance reuse)
```bash
# Force stop the instance immediately (no prompts, cluster will be lost)
$ make force-stop

# Start the instance
$ make start

# Redeploy the cluster from scratch
$ make redeploy-cluster
```

**This is the recommended workflow for quickly reusing an instance when you don't need to preserve cluster state.**

Alternative forcible stop method:
```bash
# Using interactive stop with forcible option
$ make stop
# Choose option 1 when prompted for forcible stop
```

#### Option 2: Redeploy Cluster (Clean and Rebuild)
```bash
# Redeploy the cluster (clean existing and rebuild)
$ make redeploy-cluster
```

This option:
- Automatically cleans up the existing cluster
- Supports interactive mode selection (arbiter or fencing)
- Intelligently detects cluster topology changes
- For same topology: Uses make redeploy (fast, preserves cached data)
- For topology changes: Uses make realclean + full installation (slower but clean)
- Integrates with Ansible playbooks for orchestration

**When to use redeploy:**
- When you want to refresh the cluster with the latest changes
- When the cluster is in an inconsistent state
- For testing deployment changes
- When switching between cluster modes (arbiter ↔ fencing)

#### Option 3: Delete Cluster and Clean Server
```bash
# Delete the cluster and clean the server
$ make clean

# Stop the instance
$ make stop

# When restarted, you'll need to redeploy the cluster from scratch
$ make start
# Quick deployment over clean server
$ make fencing-ipi    # Deploy fencing topology (IPI method)
$ make fencing-agent  # Deploy fencing topology (Agent method) (WIP Experimental)
$ make arbiter-ipi    # Deploy arbiter topology (IPI method)
$ make arbiter-agent  # Deploy arbiter topology (Agent method)
```

#### Option 4: Graceful Cluster Shutdown/Startup (Not recommended due to speed and consistency)
```bash
# Gracefully shutdown the cluster VMs before stopping the instance
$ make shutdown-cluster

# Stop the instance (cluster VMs are preserved in shutdown state)
$ make stop

# Start the instance again
$ make start

# Start up the cluster VMs and proxy container
$ make startup-cluster
```

## Cluster Management Details

**Important: "Clean" operations delete the cluster completely. All cluster data, configurations, and workloads will be permanently lost.**

### Clean Options
```bash
# Standard clean: Remove cluster while preserving cached data for faster redeployment
$ make clean

# Full clean: Complete cleanup including all cached data (slower but thorough)
$ make full-clean
```

**When to Use:**
- **`make clean`**: Standard cluster cleanup while preserving cached data for faster subsequent deployments
- **`make full-clean`**: Complete cleanup when you want to start completely fresh or troubleshoot deployment issues

**When to Use Each Method:**
- **Redeploy**: For changing configurations, updating cluster deployment, switching cluster modes
- **Delete and Clean**: For planned maintenance, manual control over cleanup
- **Force Stop**: For instance reuse with cluster reinstallation, when cluster is corrupted, or when cluster preservation is not needed
- **Shutdown/Startup**: For cluster state preservation

## Interactive Stop Script

When running `make stop` on an instance with a running OpenShift cluster, you'll be presented with options:

1. **Shutdown the cluster VMs**: Runs `make shutdown-cluster` first (recommended)
2. **Delete cluster and clean server**: Runs Ansible cleanup playbook
3. **Continue with forcible stop**: Stops instance immediately (cluster lost)

The script automatically detects:
- OpenShift dev-scripts installations
- Running cluster VMs
- Cluster state and provides appropriate options

## Instance Recovery Options

After restarting an instance with `make start`, you'll see guidance for:

**If you previously shutdown your cluster:**
```bash
# Start up the existing cluster
$ make startup-cluster
```

**If you need to create or redeploy a cluster:**
```bash
# Option 1: Automated redeploy with mode selection
$ make redeploy-cluster

# Option 2: Manual clean and setup approach
$ make clean
$ make arbiter-ipi #(for example)
```

### Cluster Utilities

```bash
# Build resource-agents RPM and patch all cluster nodes
$ make patch-nodes

# Collect cluster logs from all VMs
$ make get-tnf-logs
```

## Troubleshooting Cluster Management

If cluster startup fails:
```bash
# Check cluster status manually
$ make ssh
$ cd ~/openshift-metal3/dev-scripts
$ oc --kubeconfig=ocp/<cluster-name>/auth/kubeconfig get nodes

# If cluster is unrecoverable, clean and redeploy
$ make redeploy-cluster
```

If VMs don't start properly:
```bash
# Check VM states manually
$ make ssh
$ sudo virsh list --all
$ sudo virsh domstate <vm-name>

# Manually start VMs if needed
$ sudo virsh start <vm-name>
```

If proxy container issues occur:
```bash
# Check proxy container status
$ make ssh
$ podman ps --filter name=external-squid

# Restart proxy if needed
$ podman restart external-squid
```

## Advanced Features

**Cluster State Tracking:**
- State saved in `aws-hypervisor/instance-data/cluster-vm-state.json`
- Tracks deployment mode (arbiter/fencing)
- Detects configuration changes for intelligent cleanup

**VM Infrastructure Management:**
- Automatic detection of VM configuration changes
- Safe cleanup when switching between cluster types
- Preservation of VM infrastructure when possible

**Proxy Container Management:**
- Automatic proxy container lifecycle management
- Integration with cluster startup/shutdown workflows
- Status checking and recovery capabilities 