# Kepler Power Monitoring for TNF Clusters

This guide explains how to deploy Kepler power monitoring on TNF (Two Nodes with Fencing) clusters.

## Overview

[Kepler](https://sustainable-computing.io/) (Kubernetes-based Efficient Power Level Exporter) is a CNCF Sandbox project that uses eBPF to measure power consumption at container, pod, and node levels.

### Why TNF + Kepler?

| TNF Characteristic | Kepler Relevance |
|--------------------|------------------|
| Edge deployments | Power is often limited/expensive at the edge |
| Pacemaker/etcd overhead | Measure the power cost of HA components |
| Fencing events | Power cycles affect consumption patterns |

## Prerequisites

Before deploying, verify on your TNF cluster:

```bash
# Check OpenShift version (Kepler needs 4.12+)
oc version

# Check if monitoring is enabled
oc get pods -n openshift-monitoring

# Check node kernel (eBPF needs 4.18+)
oc debug node/master-0 -- chroot /host uname -r
```

## Quick Start

### From the deploy/ directory

```bash
# Deploy Kepler with Grafana
make deploy-kepler

# Remove Kepler
make remove-kepler
```

### Using Ansible directly

```bash
cd deploy/openshift-clusters

# Deploy with defaults
ansible-playbook kepler.yml -i inventory.ini

# Deploy without Grafana
ansible-playbook kepler.yml -i inventory.ini -e grafana_enabled=false

# Remove Kepler
ansible-playbook kepler.yml -i inventory.ini -e kepler_state=absent
```

### Using the scripts directly

```bash
# Deploy (with helpful output)
./deploy/openshift-clusters/scripts/deploy-kepler.sh

# Deploy without Grafana
./deploy/openshift-clusters/scripts/deploy-kepler.sh false

# Remove
./deploy/openshift-clusters/scripts/remove-kepler.sh
```

## Configuration Options

| Variable | Default | Description |
|----------|---------|-------------|
| `kepler_state` | `present` | Set to `absent` to remove |
| `kepler_namespace` | `kepler` | Namespace for Kepler components |
| `kepler_image` | `quay.io/sustainable_computing_io/kepler:v0.11.3` | Kepler image |
| `kepler_port` | `9188` | Metrics port |
| `grafana_enabled` | `true` | Deploy Grafana with dashboards |
| `grafana_namespace` | `grafana` | Namespace for Grafana |
| `grafana_image` | `docker.io/grafana/grafana:10.4.1` | Grafana image |
| `kepler_scrape_interval` | `30s` | Prometheus scrape interval |

## Accessing Dashboards

### Via Grafana (port-forward)

```bash
# Source cluster credentials
source deploy/openshift-clusters/proxy.env

# Port-forward Grafana
oc port-forward -n grafana svc/grafana 3000:3000

# Open in browser: http://localhost:3000
# Dashboard: TNF Power Monitoring
```

### Via SSH tunnel (for remote hypervisors)

```bash
ssh -L 3000:localhost:3002 ec2-user@<HYPERVISOR_IP> \
    "pkill -f 'oc port-forward.*grafana' 2>/dev/null; sleep 1; \
     export KUBECONFIG=~/openshift-metal3/dev-scripts/ocp/ostest/auth/kubeconfig && \
     oc port-forward -n grafana svc/grafana 3002:3000"
```

### Via OpenShift Console

1. Navigate to Observe -> Metrics
2. Enter query: `kepler_node_cpu_joules_total`

## Dashboard Panels

The TNF Power Monitoring dashboard includes 12 panels:

### Row 1: Key Metrics
| Panel | Description |
|-------|-------------|
| **Total Cluster Power** | Combined power of both nodes |
| **Power by Node** | Individual node consumption |
| **HA Components Power** | etcd, apiserver, MCO overhead |
| **Est. Monthly Cost** | Configurable $/kWh cost estimate |
| **Nodes Online** | Health indicator (2=healthy, 1=degraded) |

### Row 2: Time Series
| Panel | Description |
|-------|-------------|
| **Power Over Time** | Full-width time series of cluster and node power |

### Row 3: Workload Analysis
| Panel | Description |
|-------|-------------|
| **Top 10 Workloads by Power** | Non-control-plane workloads |
| **TNF Control Plane Breakdown** | HA component power details |

### Row 4: TNF-Specific Metrics
| Panel | Description |
|-------|-------------|
| **Node Power Balance** | Imbalance detection (green=balanced, red=imbalanced) |
| **etcd Power** | Dedicated etcd monitoring |
| **Power Trend (1h)** | Increasing/Stable/Decreasing indicator |

### Row 5: Correlation
| Panel | Description |
|-------|-------------|
| **CPU vs Power Correlation** | Dual-axis chart showing CPU usage vs power |

### Dashboard Variables

| Variable | Default | Description |
|----------|---------|-------------|
| Cost per kWh ($) | 0.12 | Electricity cost for monthly estimate |

### Dashboard Annotations

The dashboard includes automatic annotations:
- **Red line**: Node down event (fencing, crash)
- **Node state change**: Markers when nodes join/leave

## Key Metrics

| Metric | Description |
|--------|-------------|
| `kepler_node_cpu_joules_total` | CPU energy (joules) - use rate() for watts |
| `kepler_node_cpu_watts` | Instantaneous CPU power per node |
| `kepler_container_cpu_joules_total` | Container-level energy |
| `kepler_container_cpu_watts` | Instantaneous container power |

### Useful PromQL Queries

```promql
# Total cluster power (watts)
sum(rate(kepler_node_cpu_joules_total[5m])) * 60

# Power by node
sum by (instance) (rate(kepler_node_cpu_joules_total[5m])) * 60

# etcd power
sum(rate(kepler_container_cpu_joules_total{container_name=~".*etcd.*"}[5m])) * 60

# Node power balance (% imbalance)
((max(sum by (instance) (rate(kepler_node_cpu_joules_total[5m]))) -
  min(sum by (instance) (rate(kepler_node_cpu_joules_total[5m])))) /
 (avg(sum by (instance) (rate(kepler_node_cpu_joules_total[5m]))) + 0.0001)) * 100

# TNF control plane overhead
sum(rate(kepler_container_cpu_joules_total{
  container_name=~".*apiserver.*|.*etcd.*|.*machine-config.*"
}[5m])) * 60
```

## Claude Code Skill

A `/tnf-power` skill is available for quick power reports:

```bash
cd repos/two-node-toolbox
claude

# In Claude:
/tnf-power
```

This generates a formatted power consumption report directly from the CLI.

## Power Measurement Modes

Kepler operates in two different modes depending on your infrastructure:

### Bare Metal (Production TNF)

```
Physical Server
├── Intel/AMD CPU with RAPL
├── /sys/class/powercap/intel-rapl/ <- Real hardware registers
└── OpenShift node
    └── Kepler <- Reads REAL power in watts
```

On bare metal TNF clusters (the intended production deployment):
- Kepler reads **Intel RAPL** (Running Average Power Limit) registers
- Power measurements are **real electrical consumption** from CPU hardware
- DRAM power is also available on supported platforms
- This is the most accurate power monitoring available

### Virtualized (Dev/Test Environment)

```
Hypervisor (bare metal)
├── Real RAPL available here
└── libvirt/QEMU VMs
    ├── master-0 (no RAPL access)
    │   └── Kepler <- Uses fake-cpu-meter (simulated)
    └── master-1 (no RAPL access)
        └── Kepler <- Uses fake-cpu-meter (simulated)
```

In virtualized environments (dev-scripts, kcli, cloud VMs):
- VMs cannot access host RAPL registers (hardware isolation)
- Kepler uses **fake-cpu-meter** mode for simulated power values
- Values are proportional to CPU activity, not actual watts
- Useful for **relative comparisons**, not absolute measurements

### Automatic Detection

The Ansible role automatically detects which mode is active:
- Checks for RAPL availability in `/sys/class/powercap/intel-rapl/`
- Displays a clear message indicating the power data mode
- No configuration required - works automatically on both environments

## Known Limitations

1. **Virtual environments**: In VMs (like dev-scripts deployments), Kepler uses fake-cpu-meter mode rather than actual hardware sensors (RAPL). Power readings are proportional to CPU activity but not actual watts. This is a fundamental limitation of virtualization.

2. **Pacemaker/Corosync**: These run as systemd services on the host, not as containers. Their power consumption is included in node-level metrics but not visible as separate containers.

3. **Fencing events**: During a fence operation (node power-off), metrics will be unavailable for that node until it rejoins the cluster.

4. **RAPL coverage**: RAPL measures CPU package and DRAM power. Other components (storage, network, fans) are not included in RAPL readings.

## Troubleshooting

### Kepler pods not starting

```bash
# Check DaemonSet status
oc get ds -n kepler

# Check pod logs
oc logs -n kepler -l app.kubernetes.io/name=kepler-exporter
```

### No metrics in Prometheus

**Important context**: Kepler uses OpenShift's user workload monitoring, not the platform monitoring stack. The ServiceMonitor must be in the `kepler` namespace (not `openshift-monitoring`), and metrics are queried from `prometheus-user-workload-0` (not `prometheus-k8s-0`).

```bash
# Verify ServiceMonitor exists in kepler namespace
oc get servicemonitor -n kepler

# Check user workload monitoring is running
oc get pods -n openshift-user-workload-monitoring

# Check if Kepler target is up
oc -n openshift-user-workload-monitoring exec -c prometheus prometheus-user-workload-0 -- \
  curl -s 'http://localhost:9090/api/v1/query?query=up{job="kepler-exporter"}' | jq

# Query Kepler metrics
oc -n openshift-user-workload-monitoring exec -c prometheus prometheus-user-workload-0 -- \
  curl -s 'http://localhost:9090/api/v1/query?query=kepler_build_info' | jq '.data.result'
```

**Note**: The job name is `kepler-exporter` (from the Service name), not `kepler`.

### Grafana cannot connect to Prometheus

```bash
# Check Grafana pod logs
oc logs -n grafana -l app=grafana

# Verify ServiceAccount token exists
oc get secret grafana-token -n grafana

# Check ClusterRoleBinding
oc get clusterrolebinding grafana-cluster-monitoring-view
```

## Architecture

```
TNF Cluster
├── Kepler Namespace
│   ├── Kepler DaemonSet (runs on both nodes)
│   ├── Kepler Service (port 9188)
│   ├── ServiceMonitor (for Prometheus)
│   └── ConfigMaps (kepler-cfm, kepler-config)
│
├── OpenShift User Workload Monitoring
│   ├── Prometheus (scrapes Kepler metrics)
│   └── Thanos Querier
│
└── Grafana Namespace
    ├── Grafana Deployment
    ├── Grafana Service & Route
    ├── ConfigMap: grafana-datasources (Thanos connection)
    └── ConfigMap: tnf-power-dashboard (dashboard JSON)
```

## Files

```
repos/two-node-toolbox/
├── .claude/commands/
│   └── tnf-power.md                    # Claude skill for power reports
├── docs/kepler/
│   ├── README.md                       # This documentation
│   ├── KEPLER-ARCHITECTURE.md          # Detailed file-by-file guide
│   └── KEPLER-PRESENTATION.md          # Presentation guide
└── deploy/openshift-clusters/
    ├── kepler.yml                      # Main playbook
    ├── scripts/
    │   ├── deploy-kepler.sh            # Deployment wrapper
    │   └── remove-kepler.sh            # Removal wrapper
    └── roles/kepler/
        ├── defaults/main.yml           # Configuration variables
        ├── tasks/
        │   ├── main.yml                # Kepler deployment
        │   ├── monitoring.yml          # ServiceMonitor setup
        │   └── grafana.yml             # Grafana deployment
        └── templates/
            ├── kepler-daemonset.yaml.j2               # Kepler DaemonSet
            └── tnf-power-dashboard-cm.yaml.j2          # Grafana dashboard
```

## Resources

- [Kepler GitHub](https://github.com/sustainable-computing-io/kepler)
- [Kepler Documentation](https://sustainable-computing.io/)
- [Prometheus Naming Conventions](https://prometheus.io/docs/practices/naming/)
