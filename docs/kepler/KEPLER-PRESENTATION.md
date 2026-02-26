# Kepler Power Monitoring for TNF Clusters

## Presentation Guide

This document provides a comprehensive overview of Kepler power monitoring integration with TNF (Two Nodes with Fencing) OpenShift clusters.

---

## 1. Introduction

### What is Kepler?

**Kepler** (Kubernetes Efficient Power Level Exporter) is an open-source project that uses eBPF to probe CPU performance counters and Linux kernel tracepoints to calculate energy consumption per workload.

- **Project**: https://github.com/sustainable-computing-io/kepler
- **Maintained by**: Sustainable Computing IO (Red Hat contributors)
- **Purpose**: Expose power consumption metrics as Prometheus metrics

### Why Power Monitoring for TNF?

TNF clusters run high-availability components that consume resources:

| Component | Purpose | Power Impact |
|-----------|---------|--------------|
| **etcd** | Distributed key-value store | Continuous disk I/O and network sync |
| **Pacemaker/Corosync** | Cluster resource manager | Heartbeat monitoring, quorum checks |
| **MCO** | Machine Config Operator | Node configuration management |
| **kube-apiserver** | Kubernetes API | Request processing |

Understanding power consumption helps with:
- **Cost estimation**: Calculate electricity costs for running TNF clusters
- **Sustainability reporting**: Track carbon footprint
- **Capacity planning**: Understand resource overhead of HA components
- **Optimization**: Identify power-hungry workloads

---

## 2. Architecture

### Component Overview

```
┌──────────────────────────────────────────────────────┐
│                        TNF Cluster                   │
│                                                      │
│  ┌─────────────┐                    ┌─────────────┐  │
│  │  master-0   │                    │  master-1   │  │
│  │             │                    │             │  │
│  │ ┌─────────┐ │                    │ ┌─────────┐ │  │
│  │ │ Kepler  │ │                    │ │ Kepler  │ │  │
│  │ │DaemonSet│ │                    │ │DaemonSet│ │  │
│  │ └────┬────┘ │                    │ └────┬────┘ │  │
│  │      │:9188 │                    │      │:9188 │  │
│  └──────┼──────┘                    └──────┼──────┘  │
│         │                                  │         │
│         └──────────────┬───────────────────┘         │
│                        │                             │
│                        ▼                             │
│         ┌──────────────────────────┐                 │
│         │     ServiceMonitor       │                 │
│         │   (kepler namespace)     │                 │
│         └────────────┬─────────────┘                 │
│                      │                               │
│                      ▼                               │
│         ┌──────────────────────────┐                 │
│         │      Prometheus          │                 │
│         │(user-workload-monitoring)│                 │
│         └────────────┬─────────────┘                 │
│                      │                               │
│                      ▼                               │
│         ┌──────────────────────────┐                 │
│         │    Thanos Querier        │                 │
│         └────────────┬─────────────┘                 │
│                      │                               │
│                      ▼                               │
│         ┌──────────────────────────┐                 │
│         │       Grafana            │                 │
│         │  (TNF Power Dashboard)   │                 │
│         └──────────────────────────┘                 │
│                                                      │
└──────────────────────────────────────────────────────┘
```

### Data Flow

1. **Kepler DaemonSet** runs on each node, collects power metrics using eBPF
2. **ServiceMonitor** tells Prometheus where to scrape metrics
3. **Prometheus** (user-workload-monitoring) scrapes metrics every 30 seconds
4. **Thanos Querier** federates data from all Prometheus instances
5. **Grafana** queries Thanos and displays dashboards

### Namespaces

| Namespace | Components |
|-----------|------------|
| `kepler` | Kepler DaemonSet, Service, ServiceMonitor |
| `grafana` | Grafana Deployment, Service, Route |
| `openshift-user-workload-monitoring` | Prometheus for user workloads |
| `openshift-monitoring` | Thanos Querier, platform monitoring |

---

## 3. Power Measurement Modes

### Bare Metal (RAPL)

On physical servers with Intel/AMD CPUs, Kepler reads **RAPL** (Running Average Power Limit) registers:

- **Source**: Hardware MSR (Model-Specific Registers)
- **Accuracy**: High - actual power consumption in watts
- **Metrics**: CPU package power, DRAM power, core power

```bash
# Check if RAPL is available
ls /sys/class/powercap/intel-rapl/
```

### Virtual Machines (Estimation)

On VMs, RAPL is not accessible. Kepler uses **fake-cpu-meter** mode:

- **Source**: CPU utilization via fake-cpu-meter
- **Accuracy**: Estimated - based on CPU activity patterns
- **Metrics**: Estimated power values (may show near-zero on idle VMs)

The TNF Ansible role automatically detects the environment and displays:
- "REAL (bare metal RAPL)" - when RAPL is available
- "ESTIMATED (VM/virtualized - no RAPL)" - when running on VMs

---

## 4. Deployment

### Deployment Approach: Direct vs OLM

We chose **direct deployment** over **OLM (Operator Lifecycle Manager)** for this integration.

| Approach | How it Works |
|----------|--------------|
| **OLM** | Install operator from OperatorHub → Operator deploys workloads via Custom Resources |
| **Direct** | Ansible applies DaemonSet, Deployment, ConfigMaps directly via `oc apply` |

**Why Direct Deployment?**

| Consideration | OLM | Direct (chosen) |
|---------------|-----|-----------------|
| **Simplicity** | Requires Subscription, Operator, CR | Single playbook, no dependencies |
| **Offline/Air-gapped** | Needs OperatorHub catalog mirroring | Works with any registry access |
| **Control** | Operator manages resources | Full control over manifests |
| **Debugging** | Operator abstracts deployment | Direct visibility into all resources |
| **Dev/Test focus** | Suited for production lifecycle | Suited for dev/test environments |

For TNF development and testing environments, direct deployment provides:
- Faster iteration and debugging
- No external catalog dependencies
- Consistent behavior across environments
- Easier customization of Kepler and Grafana settings

### Prerequisites

- TNF OpenShift cluster running (4.20+)
- `oc` CLI access to the cluster
- Ansible installed locally

### One-Command Deployment

From the `deploy/` directory:

```bash
# Deploy Kepler + Grafana
make deploy-kepler

# Remove Kepler
make remove-kepler
```

### Manual Deployment

```bash
cd deploy/openshift-clusters
source proxy.env
ansible-playbook kepler.yml
```

### What Gets Deployed

1. **Kepler namespace** with:
   - ServiceAccount with privileged SCC
   - ClusterRole/ClusterRoleBinding for node/pod access
   - ConfigMap with Kepler settings (fake-cpu-meter enabled for VMs)
   - DaemonSet running Kepler on all nodes
   - Service exposing port 9188
   - ServiceMonitor for Prometheus scraping

2. **Grafana namespace** with:
   - ServiceAccount with cluster-monitoring-view permissions
   - Datasource ConfigMap (Thanos Querier with Bearer auth)
   - Dashboard ConfigMap (TNF Power Monitoring)
   - Deployment, Service, Route

---

## 5. Grafana Dashboard

### Accessing Grafana

**Via Port-Forward** (recommended for external access):

```bash
ssh -L 3000:localhost:3002 ec2-user@<HYPERVISOR_IP> \
  "export KUBECONFIG=~/openshift-metal3/dev-scripts/ocp/ostest/auth/kubeconfig && \
   oc port-forward -n grafana svc/grafana 3002:3000"
```

Then open: http://localhost:3000

### Dashboard Panels

| Panel | Description | Query |
|-------|-------------|-------|
| **Total Cluster Power** | Sum of all nodes' CPU power | `sum(rate(kepler_node_cpu_joules_total[5m])) * 60` |
| **Power by Node** | Power consumption per node | `sum by (instance) (rate(kepler_node_cpu_joules_total[5m])) * 60` |
| **HA Components Power** | Power used by etcd, MCO, apiserver | `sum(kepler_container_cpu_watts{container_name=~".*apiserver.*\|.*etcd.*"})` |
| **Est. Monthly Cost** | Estimated electricity cost | `sum(kepler_node_cpu_watts) / 1000 * 24 * 30 * $cost_per_kwh` |
| **Nodes Online** | Number of healthy nodes | `count(up{job="kepler-exporter"} == 1)` |
| **Power Over Time** | Time series of power consumption | Line graph with cluster and per-node data |
| **Top 10 Pods** | Highest power-consuming pods | `topk(10, sum by (container_name) (...))` |
| **TNF Control Plane** | Breakdown of control plane components | Bar chart of apiserver, etcd, MCO, etc. |

### Dashboard Features

- **Cost variable**: Dropdown to set electricity cost ($/kWh)
- **Fencing annotations**: Red markers when node state changes (fence events)
- **Auto-refresh**: Updates every 30 seconds

---

## 6. Useful Commands

### Verify Deployment

```bash
# Check Kepler pods
oc get pods -n kepler

# Check Grafana
oc get pods -n grafana

# Check metrics are being scraped
oc exec -n openshift-user-workload-monitoring prometheus-user-workload-0 -c prometheus -- \
  curl -s 'http://localhost:9090/api/v1/query?query=kepler_build_info' | jq
```

### Query Metrics Directly

```bash
# Total power
oc exec -n openshift-user-workload-monitoring prometheus-user-workload-0 -c prometheus -- \
  curl -s 'http://localhost:9090/api/v1/query?query=sum(kepler_node_cpu_watts)' | jq

# Power by node
oc exec -n openshift-user-workload-monitoring prometheus-user-workload-0 -c prometheus -- \
  curl -s 'http://localhost:9090/api/v1/query?query=sum%20by%20(instance)%20(kepler_node_cpu_watts)' | jq
```

### Check RAPL Availability

```bash
# From a Kepler pod
POD=$(oc get pods -n kepler -l app.kubernetes.io/name=kepler-exporter -o jsonpath='{.items[0].metadata.name}')
oc exec -n kepler $POD -- ls /sys/class/powercap/ 2>/dev/null || echo "No RAPL (VM mode)"
```

---

## 7. Limitations and Considerations

### VM Limitations

| Aspect | Bare Metal | VM |
|--------|------------|-----|
| Power Source | RAPL hardware | Estimation model |
| Accuracy | High (real watts) | Low (estimated) |
| Values | Meaningful (10-200W) | Near-zero (0.001W) |
| Use Case | Production monitoring | Development/testing |

### Known Limitations

1. **VM power values are simulated**: On VMs without RAPL, Kepler uses fake-cpu-meter which shows very low values proportional to CPU activity
2. **Node names hardcoded**: Dashboard uses `label_replace` with IPs (192.168.111.20/21) - adjust for different clusters
3. **No namespace breakdown**: Kepler's `container_name` label contains pod names, not namespace info
4. **Dashboard optimized for 2-node**: TNF-specific layout assumes master-0 and master-1

### Future Improvements

- Dynamic node name detection
- Alerts for power anomalies
- Historical cost tracking
- Redfish integration for BMC-based power readings

---

## 8. File Structure

```
deploy/openshift-clusters/
├── kepler.yml                          # Main playbook
├── roles/kepler/
│   ├── defaults/main.yml               # Default variables (image, ports)
│   ├── tasks/
│   │   ├── main.yml                    # Kepler deployment
│   │   ├── monitoring.yml              # ServiceMonitor setup
│   │   └── grafana.yml                 # Grafana deployment
│   └── templates/
│       ├── kepler-daemonset.yaml.j2    # DaemonSet template
│       └── tnf-power-dashboard-cm.yaml.j2  # Dashboard JSON
└── Makefile                            # deploy-kepler / remove-kepler targets
```

---

## 9. Demo Script

### Preparation (before presentation)

1. Ensure TNF cluster is running
2. Deploy Kepler: `make deploy-kepler`
3. Set up port-forward in a terminal
4. Open Grafana in browser, navigate to dashboard
5. Have backup screenshots ready

### Demo Flow

1. **Show the cluster**
   ```bash
   oc get nodes
   oc get pods -n kepler
   ```

2. **Explain the architecture** (use diagram above)

3. **Show Grafana dashboard**
   - Total power consumption
   - Per-node breakdown
   - HA components overhead
   - Cost estimation

4. **Show deployment simplicity**
   ```bash
   make deploy-kepler   # one command
   ```

5. **Q&A**

---

## 10. References

- Kepler Project: https://github.com/sustainable-computing-io/kepler
- Kepler Documentation: https://sustainable-computing.io/
- Red Hat Kepler Blog: https://www.redhat.com/en/blog/introducing-developer-preview-of-kepler-power-monitoring-for-red-hat-openshift
- OpenShift Power Monitoring: https://docs.redhat.com/en/documentation/openshift_container_platform/4.14/html-single/power_monitoring/index
