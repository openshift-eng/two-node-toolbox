# Valid cluster types for 'make deploy <cluster-type>'
VALID_CLUSTER_TYPES := fencing-ipi fencing-agent fencing-assisted arbiter-ipi arbiter-agent arbiter-kcli fencing-kcli sno-ipi sno-agent

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

# Handle 'make doctor <cluster-type>' pattern
# When 'doctor' is first, following cluster types select strict validation for
# that deployment; the cluster-type goals themselves are neutralized below so
# they don't trigger an actual deployment.
ifeq (doctor,$(firstword $(MAKECMDGOALS)))
  DOCTOR_ARGS := $(wordlist 2,$(words $(MAKECMDGOALS)),$(MAKECMDGOALS))
  ifneq ($(DOCTOR_ARGS),)
    DOCTOR_INVALID_ARGS := $(filter-out $(VALID_CLUSTER_TYPES),$(DOCTOR_ARGS))
    ifneq ($(DOCTOR_INVALID_ARGS),)
      $(error Unknown cluster type: '$(DOCTOR_INVALID_ARGS)'. Run 'make help' for more information.)
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

clean-spoke:
	@./openshift-clusters/scripts/clean-spoke.sh

clean-mutable-topology:
	@./openshift-clusters/scripts/clean-mutable-topology.sh $(EXTRA_ARGS)

ssh:
	@./aws-hypervisor/scripts/ssh.sh

status:
	@./openshift-clusters/scripts/status.sh

# Alias kept for muscle memory: 'make info' output is part of 'make status'
info: status

inventory:
	@./aws-hypervisor/scripts/inventory.sh

# Sync config/ files to canonical locations before targets that consume them.
create init redeploy-cluster \
baremetal-adopt baremetal-fencing-agent: sync-config

sync-config:
	@bash -c 'set -e; source ./common.sh; sync_config_files; \
	  if [ "$${CONFIG_SYNC_ERRORS:-0}" -gt 0 ]; then \
	    echo "sync-config: $${CONFIG_SYNC_ERRORS} file(s) failed to sync." >&2; exit 1; \
	  elif [ "$${CONFIG_SYNCED_COUNT:-0}" -eq 0 ]; then \
	    echo "Config files: everything up to date."; \
	  fi'

doctor:
	@./openshift-clusters/scripts/doctor.sh $(DOCTOR_ARGS)

ifeq (doctor,$(firstword $(MAKECMDGOALS)))
# Cluster types after 'doctor' are arguments to doctor.sh, not deployments
$(VALID_CLUSTER_TYPES):
	@:
else
$(VALID_CLUSTER_TYPES): sync-config
fencing-ipi:
	@./openshift-clusters/scripts/deploy-cluster.sh --topology fencing --method ipi

fencing-agent:
	@./openshift-clusters/scripts/deploy-cluster.sh --topology fencing --method agent

arbiter-ipi:
	@./openshift-clusters/scripts/deploy-cluster.sh --topology arbiter --method ipi

arbiter-agent:
	@./openshift-clusters/scripts/deploy-cluster.sh --topology arbiter --method agent

sno-ipi:
	@./openshift-clusters/scripts/deploy-cluster.sh --topology sno --method ipi

sno-agent:
	@./openshift-clusters/scripts/deploy-cluster.sh --topology sno --method agent

arbiter-kcli:
	@./openshift-clusters/scripts/deploy-cluster.sh --topology arbiter --method kcli

fencing-kcli:
	@./openshift-clusters/scripts/deploy-cluster.sh --topology fencing --method kcli

fencing-assisted:
	@$(MAKE) fencing-ipi
	@./openshift-clusters/scripts/deploy-fencing-assisted.sh
endif

keep-instance:
	@../helpers/keep-instance.sh '$(DAYS)'

baremetal-adopt:
	@./openshift-clusters/scripts/baremetal-adopt.sh

baremetal-verify:
	@./openshift-clusters/scripts/baremetal-adopt.sh --verify-only

baremetal-fencing-agent:
	@./openshift-clusters/scripts/deploy-baremetal.sh

baremetal-wizard:
	@./openshift-clusters/scripts/baremetal-wizard.sh

sno-to-3node:
	@./openshift-clusters/scripts/sno-to-3node.sh $(EXTRA_ARGS)

patch-nodes:
	@./openshift-clusters/scripts/patch-nodes.sh
get-tnf-logs:
	@./openshift-clusters/scripts/get-tnf-logs.sh

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
	@echo "  status               - Show status dashboard (instance, cluster VMs, proxy, cluster API)"
	@echo "  info                 - Alias for status"
	@echo "  inventory            - Update inventory.ini with current instance IP"
	@echo "  doctor               - Validate configuration and prerequisites (read-only)"
	@echo "  doctor <cluster-type>- Validate strictly for a specific cluster type"
	@echo "  keep-instance        - Tag instance with keep-N retention (default: 2, max: 5)"
	@echo "                         Usage: make keep-instance or make keep-instance DAYS=5"
	@echo "  sync-config          - Sync files from config/ to their canonical locations"
	@echo "                         (runs automatically before deploy and cluster targets)"
	@echo ""
	@echo "OpenShift Cluster Deployment:"
	@echo "  fencing-ipi          - Deploy fencing IPI cluster (non-interactive)"
	@echo "  fencing-agent        - Deploy fencing Agent cluster (non-interactive) (WIP Experimental)"
	@echo "  arbiter-ipi          - Deploy arbiter IPI cluster (non-interactive)"
	@echo "  arbiter-agent        - Deploy arbiter Agent cluster (non-interactive)"
	@echo "  arbiter-kcli         - Deploy arbiter cluster using kcli (non-interactive)"
	@echo "  fencing-kcli         - Deploy fencing cluster using kcli (non-interactive)"
	@echo "  fencing-assisted     - Deploy hub + spoke TNF cluster via assisted installer"
	@echo "  sno-ipi              - Deploy Single Node OpenShift (SNO) IPI cluster (non-interactive)"
	@echo "  sno-agent            - Deploy Single Node OpenShift (SNO) Agent cluster (non-interactive)"
	@echo "  sno-to-3node         - Transition existing SNO cluster to 3-node HA (platform:none)"
	@echo ""
	@echo "OpenShift Cluster Management:"
	@echo "  redeploy-cluster     - Redeploy OpenShift cluster using dev-scripts make redeploy"
	@echo "  shutdown-cluster     - Shutdown OpenShift cluster VMs in orderly fashion"
	@echo "  startup-cluster      - Start up OpenShift cluster VMs and proxy container"
	@echo "  clean                - Clean OpenShift cluster using dev-scripts clean target"
	@echo "  full-clean           - Fully clean instance cache and OpenShift cluster using dev-scripts realclean target"
	@echo "  clean-spoke          - Clean spoke cluster resources (VMs, network, auth) from assisted installer"
	@echo "  clean-mutable-topology - Remove master-1/2 VMs, disks, DHCP/DNS entries (sno-to-3node cleanup)"
	@echo "  patch-nodes          - Build resource-agents RPM and patch cluster nodes (default version: 4.11)"
	@echo ""
	@echo "Baremetal Adoption:"
	@echo "  baremetal-adopt           - Adopt baremetal nodes: validate BMC + generate dev-scripts artifacts"
	@echo "  baremetal-fencing-agent   - Deploy TNF cluster on adopted baremetal nodes via provisioning host"
	@echo "  baremetal-verify          - Verify BMC credentials for adopted baremetal nodes (no artifacts)"
	@echo "  baremetal-wizard          - Interactive wizard to create baremetal node inventory"
	@echo ""
	@echo "Cluster Utilities:"
	@echo "  get-tnf-logs         - Collect pacemaker and etcd logs from cluster nodes"

