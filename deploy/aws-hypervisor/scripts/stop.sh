#!/usr/bin/env bash

SCRIPT_DIR=$(dirname "$0")
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/../../common.sh"

set -o nounset
set -o errexit
set -o pipefail

# Configuration for wait retries
STOP_WAIT_RETRIES=${STOP_WAIT_RETRIES:-3}

# Function to wait for instance to stop with retry logic
wait_for_instance_stopped() {
    local instance_id="$1"
    local attempt=1
    
    echo "Waiting for instance to stop (max ${STOP_WAIT_RETRIES} attempts)..."
    
    while [[ $attempt -le $STOP_WAIT_RETRIES ]]; do
        echo "Attempt ${attempt}/${STOP_WAIT_RETRIES}..."
        
        set +e  # Allow this command to fail
        aws --region "${REGION}" ec2 wait instance-stopped --instance-ids "${instance_id}" --no-cli-pager
        wait_result=$?
        set -e
        
        if [[ $wait_result -eq 0 ]]; then
            echo "Instance stopped successfully."
            return 0
        fi
        
        if [[ $attempt -lt $STOP_WAIT_RETRIES ]]; then
            echo "Wait command timed out. Retrying..."
        fi
        
        attempt=$((attempt + 1))
    done
    
    echo "Error: Instance did not stop after ${STOP_WAIT_RETRIES} attempts"
    return 1
}

# Check if the instance exists and get its ID
node_dir="$(get_node_dir)"
if [[ ! -f "${node_dir}/aws-instance-id" ]]; then
    echo "Error: No instance found. Please run 'make deploy' first."
    exit 1
fi

INSTANCE_ID=$(cat "${node_dir}/aws-instance-id")
echo "Stopping instance ${INSTANCE_ID}..."

# Check current instance state
INSTANCE_STATE=$(aws --region "${REGION}" ec2 describe-instances --instance-ids "${INSTANCE_ID}" --query 'Reservations[0].Instances[0].State.Name' --output text --no-cli-pager)
echo "Current instance state: ${INSTANCE_STATE}"

# Check for running OpenShift clusters before stopping
if [[ "${INSTANCE_STATE}" == "running" ]]; then
    echo "Checking for running OpenShift clusters..."
    
    # Get the instance IP to check for clusters
    HOST_PUBLIC_IP=$(aws --region "${REGION}" ec2 describe-instances --instance-ids "${INSTANCE_ID}" --query 'Reservations[0].Instances[0].PublicIpAddress' --output text --no-cli-pager)
    
    if [[ "${HOST_PUBLIC_IP}" != "null" && "${HOST_PUBLIC_IP}" != "" ]]; then
        echo "Checking for OpenShift clusters on ${HOST_PUBLIC_IP}..."
        
        # Check if there are running dev-scripts deployments
        set +e  # Allow commands to fail
        ssh -o ConnectTimeout=10 "$(cat "${node_dir}/ssh_user")@${HOST_PUBLIC_IP}" "test -d ~/openshift-metal3" 2>/dev/null
        DEV_SCRIPTS_EXISTS=$?
        set -e
        
        if [[ ${DEV_SCRIPTS_EXISTS} -eq 0 ]]; then
            echo "Found OpenShift dev-scripts installation. Checking VM states..."
            
            # Check for running VMs
            set +e  # Allow commands to fail
            RUNNING_VMS=$(ssh -o ConnectTimeout=10 "$(cat "${node_dir}/ssh_user")@${HOST_PUBLIC_IP}" << 'EOF'
                set -e
                cd ~/openshift-metal3/dev-scripts
                
                # Source the config to get cluster name
                source common.sh
                
                # Get all VMs that belong to this cluster and are running
                VMS=$(sudo virsh list --all --name | grep "^${CLUSTER_NAME}" || true)
                
                if [[ -z "${VMS}" ]]; then
                    echo "NO_VMS_FOUND"
                    exit 0
                fi
                
                RUNNING_VMS=""
                for vm in ${VMS}; do
                    VM_STATE=$(sudo virsh domstate "${vm}" 2>/dev/null || echo "undefined")
                    if [[ "${VM_STATE}" == "running" ]]; then
                        RUNNING_VMS="${RUNNING_VMS} ${vm}"
                    fi
                done
                
                if [[ -z "${RUNNING_VMS}" ]]; then
                    echo "NO_RUNNING_VMS"
                else
                    echo "RUNNING_VMS_FOUND"
                fi
EOF
            )
            VM_CHECK_STATUS=$?
            set -e
            
            if [[ ${VM_CHECK_STATUS} -eq 0 ]]; then
                case "${RUNNING_VMS}" in
                    "NO_VMS_FOUND")
                        echo "No cluster VMs found on the instance."
                        echo "The OpenShift installation appears to be incomplete or cleaned up."
                        ;;
                    "NO_RUNNING_VMS")
                        echo "Your instance has a cluster installation but the cluster VMs are stopped."
                        echo "You can safely proceed with the instance stop."
                        ;;
                    "RUNNING_VMS_FOUND")
                        echo "WARNING: Running OpenShift cluster VMs detected on the instance."
                        echo "This instance has a running OpenShift cluster."
                        echo ""
                        echo "RECOMMENDED: Preserve your cluster with one of these options:"
                        echo "1. Shutdown the cluster VMs: make shutdown-cluster"
                        echo "2. Delete cluster and clean server: cd ../openshift-clusters && ansible-playbook clean.yml -i inventory.ini"
                        echo "3. Redeploy cluster (clean and rebuild): make redeploy-cluster"
                        echo ""
                        echo "NOTE: To force stop the instance immediately (cluster will be lost), use: make force-stop"
                        echo ""
                        read -p "Choose an option (1-3): " -n 1 -r
                        echo
                        case $REPLY in
                            1)
                                echo "Please run 'make shutdown-cluster' first, then 'make stop'"
                                exit 1
                                ;;
                            2)
                                echo "Please run 'cd ../openshift-clusters && ansible-playbook clean.yml -i inventory.ini' first, then 'make stop'"
                                exit 1
                                ;;
                            3)
                                echo "Please run 'make redeploy-cluster' first, then 'make stop'"
                                exit 1
                                ;;
                            *)
                                echo "Invalid option. Operation cancelled."
                                exit 1
                                ;;
                        esac
                        ;;
                    *)
                        echo "Could not determine VM status. Assuming cluster might be running."
                        echo "WARNING: OpenShift dev-scripts directory found on the instance."
                        echo "This instance may have a running OpenShift cluster."
                        echo ""
                        echo "RECOMMENDED: Preserve your cluster with one of these options:"
                        echo "1. Shutdown the cluster VMs: make shutdown-cluster"
                        echo "2. Delete cluster and clean server: cd ../openshift-clusters && ansible-playbook clean.yml -i inventory.ini"
                        echo "3. Redeploy cluster (clean and rebuild): make redeploy-cluster"
                        echo ""
                        echo "NOTE: To force stop the instance immediately (cluster will be lost), use: make force-stop"
                        echo ""
                        read -p "Choose an option (1-3): " -n 1 -r
                        echo
                        case $REPLY in
                            1)
                                echo "Please run 'make shutdown-cluster' first, then 'make stop'"
                                exit 1
                                ;;
                            2)
                                echo "Please run 'cd ../openshift-clusters && ansible-playbook clean.yml -i inventory.ini' first, then 'make stop'"
                                exit 1
                                ;;
                            3)
                                echo "Please run 'make redeploy-cluster' first, then 'make stop'"
                                exit 1
                                ;;
                            *)
                                echo "Invalid option. Operation cancelled."
                                exit 1
                                ;;
                        esac
                        ;;
                esac
            else
                echo "Could not check VM status. Assuming cluster might be running."
                echo "WARNING: OpenShift dev-scripts directory found on the instance."
                echo "This instance may have a running OpenShift cluster."
                echo ""
                echo "RECOMMENDED: Preserve your cluster with one of these options:"
                echo "1. Shutdown the cluster VMs: make shutdown-cluster"
                echo "2. Delete cluster and clean server: cd ../openshift-clusters && ansible-playbook clean.yml -i inventory.ini"
                echo "3. Redeploy cluster (clean and rebuild): make redeploy-cluster"
                echo ""
                echo "NOTE: To force stop the instance immediately (cluster will be lost), use: make force-stop"
                echo ""
                echo "Note: After restarting, you can redeploy the cluster with 'make redeploy-cluster'"
                echo ""
                read -p "Choose an option (1-3): " -n 1 -r
                echo
                case $REPLY in
                    1)
                        echo "Please run 'make shutdown-cluster' first, then 'make stop'"
                        exit 1
                        ;;
                    2)
                        echo "Please run 'cd ../openshift-clusters && ansible-playbook clean.yml -i inventory.ini' first, then 'make stop'"
                        exit 1
                        ;;
                    3)
                        echo "Please run 'make redeploy-cluster' first, then 'make stop'"
                        exit 1
                        ;;
                    *)
                        echo "Invalid option. Operation cancelled."
                        exit 1
                        ;;
                esac
            fi
        fi
    fi
fi

case "${INSTANCE_STATE}" in
    "stopped")
        echo "Instance is already stopped."
        ;;
    "running")
        echo "Stopping instance..."
        aws --region "${REGION}" ec2 stop-instances --instance-ids "${INSTANCE_ID}" --no-cli-pager
        wait_for_instance_stopped "${INSTANCE_ID}"
        ;;
    "stopping")
        echo "Instance is already stopping. Waiting for it to stop completely..."
        wait_for_instance_stopped "${INSTANCE_ID}"
        ;;
    "pending")
        echo "Instance is starting. Waiting for it to be running first..."
        aws --region "${REGION}" ec2 wait instance-running --instance-ids "${INSTANCE_ID}" --no-cli-pager
        echo "Now stopping instance..."
        aws --region "${REGION}" ec2 stop-instances --instance-ids "${INSTANCE_ID}" --no-cli-pager
        wait_for_instance_stopped "${INSTANCE_ID}"
        ;;
    *)
        echo "Error: Instance is in an unexpected state: ${INSTANCE_STATE}"
        exit 1
        ;;
esac

echo "Instance ${INSTANCE_ID} is now stopped."
echo ""
echo "IMPORTANT: If you had a running OpenShift cluster, it has been forcibly shut down."
echo "When you restart the instance with 'make start', you'll have these options:"
echo "1. Start the instance: make start"
echo "2. Start up the cluster: make startup-cluster (if cluster was properly shutdown)"
echo "3. Redeploy the cluster: make redeploy-cluster (clean and rebuild)"
echo ""
echo "Note: The instance can be restarted with 'make start'." 