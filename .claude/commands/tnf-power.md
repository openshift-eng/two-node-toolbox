---
description: Show TNF cluster power consumption from Kepler metrics
---

You are generating a power consumption report for a TNF (Two Nodes with Fencing) cluster using Kepler metrics.

## Step 0: Setup Cluster Access

**IMPORTANT**: Before running any `oc` commands, you MUST ensure KUBECONFIG is set.

First, check if cluster access works:
```bash
oc get nodes 2>&1 | head -3
```

If you get an error about missing config, look for and source the proxy.env file:

```bash
# Find proxy.env in the repository
PROXY_ENV=$(find . -name "proxy.env" -type f 2>/dev/null | head -1)
if [ -n "$PROXY_ENV" ]; then
  echo "Found: $PROXY_ENV"
  source "$PROXY_ENV"
  echo "KUBECONFIG=$KUBECONFIG"
fi
```

If proxy.env doesn't exist, check common locations:
- `deploy/openshift-clusters/proxy.env`
- Look for KUBECONFIG in the dev-scripts directory

Only proceed to Step 1 after `oc get nodes` works successfully.

## Prerequisites

Before running queries, verify:
1. Kepler is deployed: `oc get pods -n kepler`
2. User workload monitoring is running: `oc get pods -n openshift-user-workload-monitoring`
3. KUBECONFIG is set (handled in Step 0)

## Query Steps

### Step 1: Check Kepler Status

First, verify Kepler is running and metrics are being scraped:

```bash
# Check Kepler pods
oc get pods -n kepler -l app.kubernetes.io/name=kepler-exporter

# Check if metrics are being scraped (should return 2 targets for TNF)
oc exec -n openshift-user-workload-monitoring prometheus-user-workload-0 -c prometheus -- \
  curl -s http://localhost:9090/api/v1/targets 2>/dev/null | \
  jq '[.data.activeTargets[] | select(.labels.job == "kepler-exporter")] | length'
```

### Step 2: Check Power Measurement Mode

Determine if we're getting real or estimated power:

```bash
# Check if RAPL is available (real power) or not (estimated)
POD=$(oc get pods -n kepler -l app.kubernetes.io/name=kepler-exporter -o jsonpath='{.items[0].metadata.name}')
RAPL_CHECK=$(oc exec -n kepler $POD -- ls /sys/class/powercap/intel-rapl 2>/dev/null || echo "NOT_FOUND")
if [ -z "$RAPL_CHECK" ] || [ "$RAPL_CHECK" = "NOT_FOUND" ]; then
  echo "Mode: ESTIMATED (VMs - no RAPL hardware access)"
else
  echo "Mode: REAL (Bare metal - RAPL available)"
fi
```

### Step 3: Query Power Metrics

Run these queries against the user workload Prometheus.

**Important label notes for Kepler v0.11.x:**
- Container metrics (`kepler_container_cpu_watts`) have `namespace: kepler` (the exporter's own namespace), NOT the workload namespace
- The `container_name` label holds the pod/process name discovered by Kepler
- The `instance` label identifies which node reported the metric (e.g., `192.168.111.20:9188`)
- To find control plane components, use `container_name` regex matching against known pod prefixes

```bash
# Total cluster power (watts) - sum of node CPU power
oc exec -n openshift-user-workload-monitoring prometheus-user-workload-0 -c prometheus -- \
  curl -s 'http://localhost:9090/api/v1/query?query=sum(kepler_node_cpu_watts)' 2>/dev/null | \
  jq -r '.data.result[0].value[1] // "0"'

# Power by node (using node CPU watts)
oc exec -n openshift-user-workload-monitoring prometheus-user-workload-0 -c prometheus -- \
  curl -s 'http://localhost:9090/api/v1/query?query=sum%20by%20(instance)(kepler_node_cpu_watts)' 2>/dev/null | \
  jq -r '.data.result[] | "\(.metric.instance): \(.value[1])W"'

# Top 10 containers by power (container_name = pod/process name, instance = node)
oc exec -n openshift-user-workload-monitoring prometheus-user-workload-0 -c prometheus -- \
  curl -s 'http://localhost:9090/api/v1/query?query=topk(10,sum%20by%20(container_name,%20instance)(kepler_container_cpu_watts))' 2>/dev/null | \
  jq -r '.data.result[] | "\(.metric.container_name) [\(.metric.instance)]: \(.value[1])W"'

# Control plane component power (matched by known pod name prefixes)
# etcd
oc exec -n openshift-user-workload-monitoring prometheus-user-workload-0 -c prometheus -- \
  curl -s 'http://localhost:9090/api/v1/query?query=sum(kepler_container_cpu_watts%7Bcontainer_name%3D~%22etcd.*%22%7D)' 2>/dev/null | \
  jq -r '"etcd: \(.data.result[0].value[1] // "0")W"'

# kube-apiserver
oc exec -n openshift-user-workload-monitoring prometheus-user-workload-0 -c prometheus -- \
  curl -s 'http://localhost:9090/api/v1/query?query=sum(kepler_container_cpu_watts%7Bcontainer_name%3D~%22kube-apiserver.*%22%7D)' 2>/dev/null | \
  jq -r '"kube-apiserver: \(.data.result[0].value[1] // "0")W"'

# kube-controller-manager
oc exec -n openshift-user-workload-monitoring prometheus-user-workload-0 -c prometheus -- \
  curl -s 'http://localhost:9090/api/v1/query?query=sum(kepler_container_cpu_watts%7Bcontainer_name%3D~%22kube-controller-manager.*%22%7D)' 2>/dev/null | \
  jq -r '"kube-controller-manager: \(.data.result[0].value[1] // "0")W"'

# kube-scheduler
oc exec -n openshift-user-workload-monitoring prometheus-user-workload-0 -c prometheus -- \
  curl -s 'http://localhost:9090/api/v1/query?query=sum(kepler_container_cpu_watts%7Bcontainer_name%3D~%22kube-scheduler.*%22%7D)' 2>/dev/null | \
  jq -r '"kube-scheduler: \(.data.result[0].value[1] // "0")W"'

# Power over time using joules (rate gives watts)
oc exec -n openshift-user-workload-monitoring prometheus-user-workload-0 -c prometheus -- \
  curl -s 'http://localhost:9090/api/v1/query?query=sum(rate(kepler_node_cpu_joules_total%5B5m%5D))' 2>/dev/null | \
  jq -r '.data.result[0].value[1] // "0"'
```

**Note on metrics**:
- `kepler_node_cpu_watts` - Instantaneous CPU power per node (labels: `instance`, `zone`)
- `kepler_container_cpu_watts` - Instantaneous CPU power per container (labels: `container_name`, `instance`)
- `kepler_node_cpu_joules_total` - Cumulative energy (use `rate()` for watts)
- All container metrics report under `namespace: kepler` — use `container_name` regex to identify workloads

In **estimation mode** (VMs without RAPL), values will be very small (microwatts to milliwatts) because they're based on CPU activity models, not real power measurements. On **bare metal with RAPL**, expect realistic values (tens to hundreds of watts).

### Step 4: Get Kepler Build Info

```bash
# Kepler version and configuration
oc exec -n openshift-user-workload-monitoring prometheus-user-workload-0 -c prometheus -- \
  curl -s 'http://localhost:9090/api/v1/query?query=kepler_build_info' | \
  jq -r '.data.result[0].metric | "Version: \(.version), Branch: \(.branch)"'
```

## Output Format

Present the results in this format:

```
## TNF Cluster Power Report

**Measurement Mode**: [REAL/ESTIMATED]
**Kepler Version**: [version]
**Report Time**: [current time]

### Cluster Summary
| Metric | Value |
|--------|-------|
| Total Power | XX.X W |
| Nodes Monitored | 2 |

### Power by Node
| Node | Power (W) |
|------|-----------|
| master-0 (192.168.111.20) | XX.X |
| master-1 (192.168.111.21) | XX.X |

### TNF Control Plane Overhead
| Component | Power (W) |
|-----------|-----------|
| etcd | XX.X |
| kube-apiserver | XX.X |
| kube-controller-manager | XX.X |
| kube-scheduler | XX.X |

### Top Containers by Power
| Container (Pod) | Node | Power (W) |
|-----------------|------|-----------|
| container-1 | 192.168.111.20 | XX.X |
| container-2 | 192.168.111.21 | XX.X |
| ... | ... | ... |

---
*Note: [If ESTIMATED mode] Power values are ML-based estimates.
On production bare metal TNF clusters, real RAPL measurements are used.*
```

## Error Handling

If Kepler is not deployed:
```
Kepler is not deployed on this cluster.

To deploy Kepler power monitoring:
  cd deploy/openshift-clusters
  ansible-playbook kepler.yml -i inventory.ini

Or using make:
  cd deploy && make deploy-kepler
```

If metrics are not available:
```
Kepler pods are running but no metrics found in Prometheus.

Check:
1. ServiceMonitor exists: oc get servicemonitor -n kepler
2. User workload monitoring is enabled
3. Wait a few minutes for metrics to be scraped

Troubleshooting:
  oc logs -n kepler -l app.kubernetes.io/name=kepler-exporter --tail=50
```

## Grafana Dashboard Link

After showing the report, remind the user about the Grafana dashboard:

```
For detailed visualizations, access the Grafana dashboard:

Via port-forward (recommended for dev environments):
  oc port-forward -n grafana svc/grafana 3000:3000
  Open: http://localhost:3000

Via route (if exposed):
  URL: https://grafana-grafana.apps.<cluster-domain>

Credentials: admin / admin
Dashboard: TNF Power Monitoring
```
