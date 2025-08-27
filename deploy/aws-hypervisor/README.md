# AWS Hypervisor Scripts

This directory contains scripts for managing EC2 instances used as hypervisors for OpenShift development.

## Configuration

### Environment Setup
Copy the `instance.env.template` file to `instance.env` and set all variables to valid values for your user.

```bash
cp instance.env.template instance.env
# Edit instance.env with your specific values
```

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
Initializes a deployed instance by uploading necessary files and running initial setup. This script also generates SSH keys on the hypervisor that will be used for automatic passwordless access to cluster VMs.

```bash
./scripts/init.sh
```

**SSH Key Setup:**
- Copies your local SSH public key to the hypervisor for your access
- Generates a dedicated SSH key pair on the hypervisor for cluster VM access
- These keys enable automatic passwordless SSH from hypervisor to cluster VMs after deployment

#### `start.sh`
Starts a stopped EC2 instance and performs necessary post-startup checks.

```bash
./scripts/start.sh
```

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

#### `print_instance_data.sh`
Displays current instance information including IP addresses, instance ID, and connection details.

```bash
./scripts/print_instance_data.sh
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