# TNA/TNF Deployment Dev Guide

This guide outlines the steps and requirements for setting up a development environment and deploying a cluster using this repository, which relies on the [openshift-metal3/dev-scripts](https://github.com/openshift-metal3/dev-scripts) repository.

## High Level Deployment Diagrams

### TNA
![Diagram](./deployment-diagrams/tna.png)

### TNF
![Diagram](./deployment-diagrams/tnf.png)

## 1. Machine Requirements

To use this guide, you will need a remote machine to run the cluster on and your local machine to execute the Ansible script from.

### Client Machine Requirements:

This is the machine where you run the deployment scripts: all that's needed is Ansible.

- Make sure you have the ansible-playbook command installed.
- Install required Ansible collections:
  ```bash
  ansible-galaxy collection install -r collections/requirements.yml
  ```
  This installs:
  - `containers.podman`: For container operations
  - `community.libvirt`: For libvirt virtualization management (kcli deployments)
  - `kubernetes.core`: For Kubernetes resource management

### Remote Machine Requirements:

This is the target host where the cluster will be deployed.

- Must be a CentOS 9 or RHEL 9 host.
  - Alma and Rocky Linux 8 are also supported on a best effort basis.
  - Requires a file system that supports `d_type`. (Click [here](https://github.com/openshift-metal3/dev-scripts?tab=readme-ov-file#determining-if-your-filesystem-supports-d_type) for more info on this).
  - Ideally, it should be on a bare metal host.
  - Should have at least 64GB of RAM.
  - Needs a user with passwordless sudo access to run as.
  - You need a valid pull secret (json string) obtained from https://cloud.redhat.com/openshift/install/pull-secret.

> Note: Log in to subscription manager where appropriate for some package installs.

#### (Optional) Pre-configured remote host in AWS
If you have an AWS account available, you can use the tools in [aws-hypervisor](/deploy/aws-hypervisor/README.md) to deploy a host that will be ready to run this installation. After finishing the process, running `make info` will provide the necessary instance information to edit `inventory.ini` (see below). You can also run `make help` to see all available instance management commands.

## 2. Deploying the Cluster

The deployment process involves updating configuration files and running an Ansible playbook.

### Step 1: Update Configurations

#### Inventory file
- Copy `inventory.ini.sample` to `inventory.ini`: Edit this file to include the user and IP address of your remote machine. The ansible_ssh_extra_args are optional, but useful to keep alive the process during long installation steps.  If you are using your own server, you might need to provide a sudo password in the `ansible_become_password` variable.   
- Example: `ec2-user@100.100.100.100 ansible_ssh_extra_args='-o ServerAliveInterval=30 -o ServerAliveCountMax=120'`. 
- If you provisioned an AWS hypervisor using the [aws-hypervisor](/deploy/aws-hypervisor/) tools, it is recommended to use the "make inventory" option from the deploy directory, which will create a pre-filled inventory file with your AWS instance data. 

#### Config files for dev-scripts
- In `roles/install-dev/files/`, review `config_XXXXX_example.sh` files and copy them to `config_XXXXX.sh` as needed, removing the `_example` from the filename.
- The config file for each topology is slightly different. Sample `config_arbiter_example.sh` and `config_fencing_example.sh` files are provided, ready to use with the AWS dev hypervisor. You can change the variables inside (see Note below), but when copying them, the expected file names are `config_arbiter.sh` and `config_fencing.sh`.
- The arbiter config file contains separate configuration sections for IPI and Agent-based installations. Use the appropriate section based on your chosen installation method.
- Unless you're using `OPENSHIFT_CI="True"` to avoid using private images, you should fill CI_TOKEN with your own token. You can get it from https://console-openshift-console.apps.ci.l2s4.p1.openshiftapps.com. Start by clicking your name in the top right and clicking "copy login command." At this point, a new window will open, and you should click on "Display Token." It should now display an API token you can copy over to your profile.
- Modify the `OPENSHIFT_RELEASE_IMAGE` variable in this file with your desired image.
- Example: `OPENSHIFT_RELEASE_IMAGE=quay.io/openshift-release-dev/ocp-release:4.19.0-rc.5-multi-x86_64`.
<br /> 
  > Note: The config.sh file is passed to metal-scripts. A full list of acceptable values can be found by checking the linked config_example.sh file in the [openshift-metal3/dev-scripts/config_example.sh](https://github.com/openshift-metal3/dev-scripts/blob/master/config_example.sh) repository.

#### Pull secret
- Create `pull-secret.json`: Create a file named pull-secret.json in the `roles/dev-scripts/install-dev/files/` directory and paste your pull secret JSON string into it.


#### SSH access (optional)
- Public Key Access: For convenience, your local public key is added to the authorized keys on the remote host.

  - This guide assumes your public key is located at `~/.ssh/id_ed25519.pub`.
    If your public key path is different, you need to update this path in the file roles/config/tasks/main.yaml.


### Step 2: Run Deployment

- Execute the command ansible-playbook setup.yml -i inventory.ini to start the deployment process.
  - You will be prompted to choose the installation mode for the desired topology: arbiter or fencing.
  - For arbiter topology, you will also be prompted to choose the installation method: ipi or agent.
  - Then you will be asked to confirm the config_X.sh file name. 
- This process will take between 30 and 60 minutes, so be prepared for it to run for some time. The sample inventory.ini provided already accounts for this and provides an Ansible variable to keep the SSH connection alive. 
Usually the longest task is `[install-dev: Start Openshift]`, which includes downloading all necessary images and provisioning the VMs and the actual OCP cluster. 
If you want to check the progress of the installation you can review or follow the logs produced by dev-scripts on `/home/<user>/openshift-metal3/dev-scripts/logs/`.
- Once the playbook is finished, a file named `proxy.env` will be created containing the proxy configs to connect to the cluster.
- Source the `proxy.env` file by running `source proxy.env`.
- After sourcing the file, you should be able to run oc get nodes to see the nodes running in your deployed cluster.

> Note: The proxy.env file automatically detects its location and sets the correct absolute path for the kubeconfig, making it work from any directory where it's sourced.

### Alternative: Direct Access from Hypervisor

For direct cluster access **from within the hypervisor host** (not from your local machine), authentication files are automatically copied to a standard location:

```
~/auth/kubeconfig          # Cluster admin kubeconfig  
~/auth/kubeadmin-password   # Default admin password
```

**From the hypervisor host only**, you can access the cluster directly:
```bash
# SSH into the hypervisor first
ssh your-hypervisor-host

# Option 1: Use default kubeconfig location (recommended)
oc get nodes

# Option 2: Explicitly set KUBECONFIG environment variable
export KUBECONFIG=~/auth/kubeconfig
oc get nodes

# Get admin password for web console
cat ~/auth/kubeadmin-password
```

The deployment automatically creates a symlink from `~/.kube/config` to `~/auth/kubeconfig`, so `oc` commands work without setting the `KUBECONFIG` environment variable.

**Note**: This direct access only works from within the hypervisor. For access from your local machine, use the proxy setup described above.

### Optional: Accessing the Console WebUI

If you wish to reach the Console WebUI, you can use any preferred proxy extension on your browser to do so.

- Using the `proxy.env` from the previous step, set the public IP address and port number in your proxy extension.
- After the install, the `kubeadmin-password` file will be saved to be used with the default `kubeadmin` user.
- Run `oc get routes console -n openshift-console -ojsonpath='{.spec.host}{"\n"}'` to get the Console URL, if you don't already know what it is.
- You should be able to reach it in your browser and login as normal.

> Note: remember to turn off your proxy extension after you are finished.

#### Non-interactive usage
- The topology of the cluster (installation mode) can be selected through the Ansible variable "topology"
- For arbiter topology, you can also specify the installation method using the "method" variable (ipi or agent)
- If you are running this installation non-interactively, you can set variables to avoid all the prompts
  > Examples:
 ansible-playbook setup.yml -e "topology=arbiter" -e "interactive_mode=false" -i inventory.ini
 ansible-playbook setup.yml -e "topology=arbiter" -e "method=agent" -e "interactive_mode=false" -i inventory.ini

#### Redfish Stonith Configuration

For more information on STONITH, go to the [official RHEL HA documentation](https://docs.redhat.com/en/documentation/red_hat_enterprise_linux/9/html/configuring_and_managing_high_availability_clusters/assembly_configuring-fencing-configuring-and-managing-high-availability-clusters)

For clusters using the fencing topology on OpenShift 4.19.x, automatic Redfish stonith configuration is available. This feature configures Pacemaker stonith resources using Redfish fencing for BareMetalHost resources.

Redfish configuration can be applied in two ways:

**Integrated Usage:**
- When running the main deployment playbook in interactive mode with fencing topology, you will be prompted to configure Redfish stonith automatically
- Redfish configuration runs as part of the main deployment workflow

**Standalone Usage:**
- Redfish configuration can be run independently using: `ansible-playbook redfish.yml`
- This allows for running it separately from the main deployment or re-running it if needed

For detailed configuration options, verification commands, and requirements, refer to the [Redfish role documentation](roles/redfish/README.md).


### Optional: Attaching Extra Disks

- If your deployment requires extra disks, make sure you have the disks on the remote host.
- Then, use the attach-disk command to connect them to the virtual machines (VMs).
  - Example: `sudo virsh attach-disk ostest_arbiter_0 /dev/nvme2n1 vdc`.

#### Pool Volumes As Disks

Sometimes it is required to use a `pool volume` to be able to attach disk volumes to VMs with ROTA 0.
Make sure the desired path on disk has enough space and follow the helper bash functions below.

In order to present a disk drive as an SSD with ROTA 0 in a guest VM it is easier to create a pool and volumes
and attach them as a disk object to a guest VM. Please use the helper scripts below to help create and attach the volumes.

- First use `create_pool <pool_name> <host_storage_directory>` if one does not exist already, this will create, start, and set autostart on that pool.
- Second use `create_volume <volume_name> <pool_name> <capacity>` to create the volume with the specified name attached to the pool that was created with a desired capacity.
- Lastly use `attach_volume_to_vm <vm_name> <pool_name> <volume_name>` to attach the created device to the guest VM, please modify the function if the device name inside the guest VM is already taken.

```bash
# Create a pool to use if you don't already have one.
function create_pool {
    local pool_name=$1
    local pool_path=$2
    sudo virsh pool-define-as --name "${pool_name}" --type dir  --target "${pool_path}"
    sudo virsh pool-build "${pool_name}"
    sudo virsh pool-start "${pool_name}"
    sudo virsh pool-autostart "${pool_name}"
}

# Create a volume in that pool.
function create_volume {
    local vol_name=$1
    local pool_name=$2
    local capacity="${3:-30G}"
    sudo virsh vol-create-as --pool "${pool_name}" --name "${vol_name}" --capacity "${capacity}" --format qcow2
}

# Attach the volume to the VM
function attach_volume_to_vm {
    local vm_name=$1
    local pool_name=$2
    local volume_name=$3
    local DEVICE_NAME=sdh # Change this if it's already occupied in the guest machine
    sudo virsh attach-device "${vm_name}" /dev/stdin --persistent << EOF
    <disk type='volume' device='disk'>
      <driver name='qemu' type='qcow2' discard='unmap'/>
      <source pool="${pool_name}" volume="${volume_name}"/>
      <target dev="${DEVICE_NAME}" bus='scsi' rotation_rate='1'/>
    </disk>
EOF
}
```

### Troubleshooting Connection Issues:

- If you lose the ability to reach your cluster, it's likely an issue with the proxy container on the remote host.
  - SSH into the remote host (you can run `make ssh` from the aws-hypervisor folder).
  - Validate that the external-squid pod is running `podman ps`. You should see output containing the following:
`...  quay.io/openshifttest/squid-proxy:multiarch  /bin/sh -c /usr/l...   Up 27 seconds external-squid ...
`
  - If it's not running, restart it using the command `podman restart external-squid`.

### Troubleshooting installation issues

- A significant part of the installation time is spent downloading the necessary images. If you think the process might be stuck, you can check the /opt/dev-scripts/ironic/html/images to see if the download is progressing. 
- Logs for dev-scripts are available in $home/openshift-metal3/dev-scripts/logs, and they will contain useful information to help with your issue


## 3. Cleaning Up

To shut down and clean up the deployed environment:

- From the deploy directory, run `make clean` for standard cleanup or `make full-clean` for complete cleanup
- Alternatively, you can run the ansible playbook directly: `ansible-playbook clean.yml -i inventory.ini`

After cleaning up, you can re-create the deployment using a different payload image if desired.
