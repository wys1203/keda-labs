# keda-labs

Reusable kind lab for KEDA experiments on Kubernetes `1.24.17` with:

- `1` control-plane and `3` worker nodes
- zone labels: `topology.kubernetes.io/zone=dc1|dc2|dc3`
- KEDA `2.18.3` with operator + metrics-apiserver + admission-webhooks Prometheus endpoints enabled
- Prometheus + Alertmanager + kube-state-metrics + node-exporter
- Grafana `11` provisioned with two dashboards (control-plane health, demo CPU autoscaling)
- KEDA-specific alert rules (component down, reconcile errors, adapter↔operator gRPC errors, scaler errors, demo HPA pinned at max, demo pods Pending)
- Two demo workloads — one with a CPU (resource) trigger, one with a Prometheus (external) trigger — so every KEDA metric path is exercised

## Prerequisites

- Docker
- kind
- kubectl
- Helm
- make

## Quick start

```bash
make up
make status
make load-test
make grafana
```

Grafana is exposed locally through `kubectl port-forward` at `http://localhost:3000`
(default credentials `admin`/`admin`). Open the **KEDA Lab** folder for the
provisioned dashboards.

## Common commands

```bash
make help           # list every target
make recreate       # delete and rebuild the cluster
make demo           # (re)deploy the cpu-demo workload
make load-test      # patch the demo into a busy loop and watch KEDA scale
make verify         # post-install sanity checks
make grafana        # port-forward Grafana to :3000
make prometheus     # port-forward Prometheus to :9090
make alertmanager   # port-forward Alertmanager to :9093
make logs           # tail KEDA + demo logs
make down           # tear the cluster down
```

## Monitoring

### Prometheus targets

`keda/values.yaml` enables `prometheus.<operator|metricServer|webhooks>.enabled`,
which makes the chart annotate the three KEDA Services with
`prometheus.io/scrape=true`. The upstream prometheus-community chart's
`kubernetes-service-endpoints` scrape job picks them up automatically.

Verify:

```bash
kubectl -n monitoring exec deploy/prometheus-server -c prometheus-server -- \
  wget -q -O - 'http://localhost:9090/api/v1/query?query=up{namespace="keda"}'
```

You should see one healthy `up==1` target each for `keda-operator`,
`keda-operator-metrics-apiserver`, and `keda-admission-webhooks` under the
`kubernetes-service-endpoints` job.

> Why all queries pin `job="kubernetes-service-endpoints"`: the chart
> additionally hardcodes pod-level `prometheus.io/scrape` annotations on the
> metrics-apiserver, which causes the `kubernetes-pods` job to scrape it a
> second time. Pinning the job label deduplicates without disabling the
> chart's defaults.

### Why two demo workloads

KEDA emits two distinct families of metrics depending on the trigger type:

| Trigger family | Examples | Path through KEDA | Metrics that populate |
| --- | --- | --- | --- |
| Resource (cpu, memory) | `manifests/demo-cpu` | KEDA creates an HPA with a `Resource` metric source. metrics-server feeds the HPA directly — KEDA's adapter is **not** in the loop. | `keda_resource_registered_total`, `keda_scaled_object_*`, `controller_runtime_*`, `workqueue_*` |
| External (prometheus, kafka, ...) | `manifests/demo-prom` | KEDA creates an HPA with an `External` metric source. The kube-apiserver routes that to KEDA's metrics-apiserver, which calls the operator over gRPC. | All of the above **plus** `keda_scaler_*` and `keda_internal_metricsservice_grpc_*` (server + client side) |

Both are deployed by `make demo` (and `make up`). The Prometheus-trigger
demo's query reads the cpu-demo's CPU usage, so a single
`make load-test` exercises both paths simultaneously and lights up every
panel on *KEDA Operations*.

### Grafana dashboards

Two dashboards are provisioned from `grafana/dashboards/`:

| UID | Title | Use it for |
| --- | --- | --- |
| `keda-operations` | KEDA Operations | KEDA control-plane health: pod up state, reconcile errors, reconcile latency, workqueue depth, component CPU/RAM, **adapter ↔ operator gRPC** traffic + latency, **external scaler** activity / latency / errors. |
| `keda-demo-cpu-scaling` | KEDA Demo - CPU Autoscaling | The cpu-demo workload: replicas (current vs desired vs min/max), per-pod CPU vs request, utilization vs the 50% trigger threshold, pod phases, zone spread, firing-alerts table. |

### Alerts

`prometheus/values.yaml` ships three rule groups:

- `keda-control-plane` — `KedaOperatorDown`, `KedaMetricsApiServerDown`,
  `KedaAdmissionWebhooksDown`, `KedaReconcileErrors`, `KedaWorkqueueBacklog`,
  `KedaAdapterToOperatorGrpcErrors`.
- `keda-scalers` — `KedaScaledObjectErrors`, `KedaScalerErrors`,
  `KedaScalerMetricsLatencyHigh` (active only with external triggers).
- `demo-cpu-workload` — `DemoCpuAtMaxReplicas`, `DemoCpuPodsPending`.

Inspect them in Prometheus (`make prometheus`, then
`http://localhost:9090/alerts`) or in Alertmanager
(`make alertmanager`, then `http://localhost:9093`).

To exercise the pipeline end-to-end:

```bash
make load-test LOAD_DURATION=900   # ≥10m sustains DemoCpuAtMaxReplicas to firing
```

After ~10 minutes at max replicas, `DemoCpuAtMaxReplicas` transitions
`pending → firing` and is forwarded to Alertmanager.

## Notes

- `make up` installs metrics-server, Prometheus, Alertmanager, kube-state-metrics,
  node-exporter, Grafana, and KEDA, then deploys the CPU demo workload.
- `make load-test` temporarily patches the demo container into a busy loop so
  KEDA can scale it up; it restores the idle command on exit.
- The `monitoring` namespace hosts Prometheus, Alertmanager, Grafana, and the
  metrics exporters. The `keda` namespace hosts KEDA itself. The `demo-cpu`
  and `demo-prom` namespaces host the two demo workloads.
- Helm values live next to the install scripts: `keda/values.yaml`,
  `prometheus/values.yaml`, `grafana/values.yaml`. Edit those, then re-run the
  matching `make install-*` target — no full cluster recreate needed.
