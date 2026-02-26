# Valid cluster types for 'make deploy <cluster-type>'
VALID_CLUSTER_TYPES := fencing-ipi fencing-agent arbiter-ipi arbiter-agent arbiter-kcli fencing-kcli

# Handle 'make deploy <cluster-type>' pattern
# When 'deploy' is first, validate any following arguments are valid cluster types
ifeq (deploy,$(firstword $(MAKECMDGOALS)))
  DEPLOY_ARGS := $(wordlist 2,$(words $(MAKECMDGOALS)),$(MAKECMDGOALS))
  ifneq ($(DEPLOY_ARGS),)
    INVALID_ARGS := $(filter-out $(VALID_CLUSTER_TYPES),$(DEPLOY_ARGS))
    ifneq ($(INVALID_ARGS),)
      $(error Unknown cluster type: '$(INVALID_ARGS)'. Run 'make help' for more information.)
    endif
  endif
endif

create:
	@./aws-hypervisor/scripts/create.sh

deploy:
	@$(MAKE) create init inventory

init:
	@./aws-hypervisor/scripts/init.sh

destroy:
	@./aws-hypervisor/scripts/destroy.sh

start:
	@./aws-hypervisor/scripts/start.sh

stop:
	@./aws-hypervisor/scripts/stop.sh

force-stop:
	@./aws-hypervisor/scripts/force-stop.sh

redeploy-cluster:
	@./openshift-clusters/scripts/redeploy-cluster.sh

shutdown-cluster:
	@./openshift-clusters/scripts/shutdown-cluster.sh

startup-cluster:
	@./openshift-clusters/scripts/startup-cluster.sh

clean:
	@./openshift-clusters/scripts/clean.sh

full-clean:
	@./openshift-clusters/scripts/full-clean.sh

ssh:
	@./aws-hypervisor/scripts/ssh.sh

info:
	@./aws-hypervisor/scripts/print_instance_data.sh

inventory:
	@./aws-hypervisor/scripts/inventory.sh

fencing-ipi:
	@./openshift-clusters/scripts/deploy-cluster.sh --topology fencing --method ipi

fencing-agent:
	@./openshift-clusters/scripts/deploy-cluster.sh --topology fencing --method agent

arbiter-ipi:
	@./openshift-clusters/scripts/deploy-cluster.sh --topology arbiter --method ipi

arbiter-agent:
	@./openshift-clusters/scripts/deploy-cluster.sh --topology arbiter --method agent

arbiter-kcli:
	@./openshift-clusters/scripts/deploy-cluster.sh --topology arbiter --method kcli

fencing-kcli:
	@./openshift-clusters/scripts/deploy-cluster.sh --topology fencing --method kcli

patch-nodes:
	@./openshift-clusters/scripts/patch-nodes.sh
get-tnf-logs:
	@./openshift-clusters/scripts/get-tnf-logs.sh

deploy-kepler:
	@./openshift-clusters/scripts/deploy-kepler.sh

remove-kepler:
	@./openshift-clusters/scripts/remove-kepler.sh

help:
	@echo "Available commands:"
	@echo ""
	@echo "Instance Lifecycle Management:"
	@echo "  deploy               - Create, initialize, and update inventory for new EC2 instance"
	@echo "  deploy <cluster-type>- Deploy EC2 instance AND deploy the specified cluster type"
	@echo "	 		 Valid types: $(VALID_CLUSTER_TYPES)"
	@echo "  create               - Create new EC2 instance"
	@echo "  init                 - Initialize deployed instance"
	@echo "  start                - Start stopped EC2 instance"
	@echo "  stop                 - Stop running EC2 instance gracefully (interactive cluster handling)"
	@echo "  force-stop           - Force stop EC2 instance immediately (no cluster checks)"
	@echo "  destroy              - Completely destroy EC2 instance and all resources"
	@echo ""
	@echo "Instance Utils:"
	@echo "  ssh                  - SSH into the EC2 instance"
	@echo "  info                 - Display instance information"
	@echo "  inventory            - Update inventory.ini with current instance IP"
	@echo ""
	@echo "OpenShift Cluster Deployment:"
	@echo "  fencing-ipi          - Deploy fencing IPI cluster (non-interactive)"
	@echo "  fencing-agent        - Deploy fencing Agent cluster (non-interactive) (WIP Experimental)"
	@echo "  arbiter-ipi          - Deploy arbiter IPI cluster (non-interactive)"
	@echo "  arbiter-agent        - Deploy arbiter Agent cluster (non-interactive)"
	@echo "  arbiter-kcli         - Deploy arbiter cluster using kcli (non-interactive)"
	@echo "  fencing-kcli         - Deploy fencing cluster using kcli (non-interactive)"
	@echo ""
	@echo "OpenShift Cluster Management:"
	@echo "  redeploy-cluster     - Redeploy OpenShift cluster using dev-scripts make redeploy"
	@echo "  shutdown-cluster     - Shutdown OpenShift cluster VMs in orderly fashion"
	@echo "  startup-cluster      - Start up OpenShift cluster VMs and proxy container"
	@echo "  clean                - Clean OpenShift cluster using dev-scripts clean target"
	@echo "  full-clean           - Fully clean instance cache and OpenShift cluster using dev-scripts realclean target"
	@echo "  patch-nodes          - Build resource-agents RPM and patch cluster nodes (default version: 4.11)"
	@echo ""
	@echo "Cluster Utilities:"
	@echo "  get-tnf-logs         - Collect pacemaker and etcd logs from cluster nodes"
	@echo ""
	@echo "Power Monitoring:"
	@echo "  deploy-kepler        - Deploy Kepler power monitoring (v0.11.3)"
	@echo "  remove-kepler        - Remove Kepler power monitoring from cluster"

