# Kepler Architecture & File Guide

This document explains each Kepler file, what it does, and how they work together.

---

## Architecture Overview

```
User runs: make deploy-kepler
                │
                ▼
        deploy-kepler.sh (wrapper script)
                │
                ▼
        kepler.yml (main playbook)
                │
                ▼
    ┌───────────┴───────────┐
    │     roles/kepler/     │
    │                       │
    │  defaults/main.yml    │ ← Variables
    │         │             │
    │         ▼             │
    │  tasks/main.yml       │ ← Deploy Kepler DaemonSet
    │         │             │
    │         ▼             │
    │  tasks/monitoring.yml │ ← Create ServiceMonitor
    │         │             │
    │         ▼             │
    │  tasks/grafana.yml    │ ← Deploy Grafana + Dashboard
    │                       │
    │  templates/*.j2       │ ← Kubernetes manifests
    └───────────────────────┘
                │
                ▼
        TNF Cluster with Kepler running
```

---

## 1. Entry Points

### `scripts/deploy-kepler.sh`

**Purpose:** Wrapper script that users call to deploy Kepler.

**Flow:**
1. Check inventory.ini exists
2. Run: `ansible-playbook kepler.yml -i inventory.ini`
3. Print success message with Grafana access instructions

**Usage:** `make deploy-kepler` or `./scripts/deploy-kepler.sh`

---

### `scripts/remove-kepler.sh`

**Purpose:** Wrapper script to remove Kepler from cluster.

**Flow:** Runs `ansible-playbook kepler.yml -i inventory.ini -e kepler_state=absent`

---

### `kepler.yml`

**Purpose:** Main Ansible playbook - orchestrates the entire deployment.

**Flow:**
1. **PRE-TASKS:** Setup cluster access
   - Check if proxy.env exists
   - Extract KUBECONFIG from proxy.env
   - Verify cluster access with: `oc get namespace default`

2. **ROLES:** Call the kepler role
   - Triggers `roles/kepler/tasks/main.yml`

3. **POST-TASKS:** Print summary with useful commands

**Key variables passed to role:**
- `kepler_state`: "present" (deploy) or "absent" (remove)
- `grafana_enabled`: true/false
- `proxy_kubeconfig`: Path to kubeconfig

---

## 2. Ansible Role

### `roles/kepler/defaults/main.yml`

**Purpose:** Defines default configuration values.

| Variable | Default | Description |
|----------|---------|-------------|
| `kepler_namespace` | `kepler` | Namespace for Kepler components |
| `kepler_image` | `quay.io/.../kepler:v0.11.3` | Kepler container image |
| `kepler_port` | `9188` | Metrics endpoint port |
| `grafana_enabled` | `true` | Deploy Grafana dashboard |
| `grafana_namespace` | `grafana` | Namespace for Grafana |
| `grafana_image` | `grafana/grafana:10.4.1` | Grafana container image |
| `kepler_scrape_interval` | `30s` | Prometheus scrape interval |
| `kepler_state` | `present` | Deploy or remove (`absent`) |
| `operator_ready_retries` | `30` | Timeout retries (30 × 10s = 5min) |

**Override:** Pass `-e variable=value` to ansible-playbook

---

### `roles/kepler/tasks/main.yml`

**Purpose:** Deploys Kepler exporter DaemonSet on all nodes.

**Flow when `kepler_state == "present"`:**

1. Set KUBECONFIG environment
2. Create namespace `kepler`
3. Create ServiceAccount `kepler-sa`
4. Create ClusterRole (get/list/watch: nodes, pods, namespaces)
5. Create ClusterRoleBinding
6. Add kepler-sa to privileged SCC (required for eBPF)
7. Create ConfigMap `kepler-cfm` (environment settings)
8. Create ConfigMap `kepler-config` (kepler.yaml with fake-cpu-meter for VMs)
9. Generate DaemonSet from template (`kepler-daemonset.yaml.j2`)
10. Create Kepler Service (port 9188)
11. Wait for DaemonSet ready (up to 5 min)
12. Check RAPL availability (`/sys/class/powercap/intel-rapl/`)
13. Display mode: REAL (RAPL) or ESTIMATED (VM)
14. Include `monitoring.yml`
15. Include `grafana.yml` (if enabled)

**Flow when `kepler_state == "absent"`:**
- Delete all resources in reverse order

---

### `roles/kepler/tasks/monitoring.yml`

**Purpose:** Configures OpenShift to scrape Kepler metrics.

**Flow:**

1. **Enable user workload monitoring**
   - Creates ConfigMap `cluster-monitoring-config` in `openshift-monitoring`
   - Sets `enableUserWorkload: true`
   - This starts `prometheus-user-workload` pods

2. **Wait for monitoring ready**
   - Checks prometheus-operator deployment

3. **Create ServiceMonitor in kepler namespace**
   ```yaml
   ServiceMonitor: kepler
   namespace: kepler  # IMPORTANT - must match workload namespace
   spec:
     endpoints:
       - port: http
         interval: 30s
     selector:
       matchLabels:
         app.kubernetes.io/name: kepler-exporter
   ```

**Why namespace matters:** ServiceMonitor must be in `kepler` namespace (same as workload) for user-workload-monitoring to discover it. NOT in `openshift-monitoring`.

---

### `roles/kepler/tasks/grafana.yml`

**Purpose:** Deploys Grafana with pre-configured TNF power dashboard.

**Flow:**

1. Create namespace `grafana`
2. Create ServiceAccount `grafana`
3. Create ClusterRoleBinding to `cluster-monitoring-view` role
4. Create ServiceAccount token Secret
5. Wait for token, decode it → `grafana_sa_token`
6. Create datasource ConfigMap (Thanos Querier with Bearer auth)
7. Create dashboard provisioning ConfigMap
8. Generate dashboard from template (`tnf-power-dashboard-cm.yaml.j2`)
9. Deploy Grafana Deployment:
   - Anonymous auth enabled (Admin role)
   - Mounts datasources and dashboards
10. Create Service (port 3000)
11. Create Route (HTTPS edge termination)
12. Wait for Grafana ready
13. Print access URL and RAPL mode

---

## 3. Templates

### `templates/kepler-daemonset.yaml.j2`

**Purpose:** Kubernetes DaemonSet manifest for Kepler.

**Key configuration:**

| Setting | Value | Why |
|---------|-------|-----|
| `privileged: true` | Required | eBPF access |
| `hostNetwork: true` | Required | Host network access |
| `hostPID: true` | Required | Host process access |
| `runAsUser: 0` | Required | Root for kernel access |

**Tolerations:** Runs on control-plane nodes (master/control-plane)

**Volume mounts:**
- `/lib/modules` - Kernel modules
- `/sys/kernel/tracing` - eBPF tracing
- `/sys/kernel/debug` - Kernel debug
- `/usr/src/kernels` - Kernel source
- `/proc` - Process info

---

### `templates/tnf-power-dashboard-cm.yaml.j2`

**Purpose:** Grafana dashboard JSON as ConfigMap.

**Dashboard panels (12 total):**

| Row | Panels |
|-----|--------|
| 1 | Total Cluster Power, Power by Node, HA Components, Est. Monthly Cost, Nodes Online |
| 2 | Power Over Time (full-width graph) |
| 3 | Top 10 Workloads, TNF Control Plane Breakdown |
| 4 | Node Power Balance, etcd Power, Power Trend (1h) |
| 5 | CPU vs Power Correlation |

**Annotations:**
- Red line: Node down event
- Node state change markers

**Variables:**
- `cost_per_kwh`: Dropdown for electricity cost

**Key PromQL queries:**

| Metric | Query |
|--------|-------|
| Total Power | `sum(rate(kepler_node_cpu_joules_total[5m])) * 60` |
| Power by Node | `sum by (instance) (rate(kepler_node_cpu_joules_total[5m])) * 60` |
| Node Balance | `((max(...) - min(...)) / avg(...)) * 100` |
| etcd Power | `sum(rate(kepler_container_cpu_joules_total{container_name=~".*etcd.*"}[5m])) * 60` |

---

## 4. Claude Skill

### `.claude/commands/tnf-power.md`

**Purpose:** Quick power reports via `/tnf-power` command.

**Flow:**
1. Check KUBECONFIG / source proxy.env
2. Verify Kepler pods running
3. Check RAPL availability (REAL vs ESTIMATED)
4. Query Prometheus for metrics
5. Format and display power report
6. Show Grafana access instructions

---

## Data Flow

```
┌─────────────────────────────────────────────────────────────┐
│                      TNF Cluster                            │
│                                                             │
│   master-0                              master-1            │
│  ┌──────────┐                          ┌──────────┐         │
│  │ Kepler   │  Reads CPU counters      │ Kepler   │         │
│  │ Pod      │  via eBPF (or RAPL       │ Pod      │         │
│  │ :9188    │  on bare metal)          │ :9188    │         │
│  └────┬─────┘                          └────┬─────┘         │
│       │                                      │              │
│       └──────────────┬───────────────────────┘              │
│                      │                                      │
│                      ▼                                      │
│         ┌────────────────────────┐                          │
│         │ ServiceMonitor         │                          │
│         │ (kepler namespace)     │                          │
│         └───────────┬────────────┘                          │
│                     │ "Scrape :9188 every 30s"              │
│                     ▼                                       │
│         ┌────────────────────────┐                          │
│         │ Prometheus             │                          │
│         │ (user-workload-        │                          │
│         │  monitoring)           │                          │
│         └───────────┬────────────┘                          │
│                     │                                       │
│                     ▼                                       │
│         ┌────────────────────────┐                          │
│         │ Thanos Querier         │                          │
│         │ (openshift-monitoring) │                          │
│         └───────────┬────────────┘                          │
│                     │ Bearer token auth                     │
│                     ▼                                       │
│         ┌────────────────────────┐                          │
│         │ Grafana                │                          │
│         │ "TNF Power Monitoring" │                          │
│         └────────────────────────┘                          │
│                                                             │
└─────────────────────────────────────────────────────────────┘
```

---

## Power Measurement Modes

| Mode | Environment | Source | Accuracy |
|------|-------------|--------|----------|
| **REAL** | Bare metal | Intel RAPL registers | High (actual watts) |
| **ESTIMATED** | VMs | fake-cpu-meter | Low (proportional to CPU activity) |

The deployment automatically detects which mode is available by checking `/sys/class/powercap/intel-rapl/`.

**Note:** For accurate power readings, deploy on bare metal with Intel CPUs (RAPL support) or servers with Redfish-enabled BMC (Kepler v0.11.0+).
