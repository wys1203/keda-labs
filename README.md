# keda-labs

Reusable kind lab for KEDA experiments on Kubernetes `1.24.17` with:

- `1` control-plane and `3` worker nodes
- zone labels: `topology.kubernetes.io/zone=dc1|dc2|dc3`
- cert-manager `v1.16.2` issues KEDA's webhook / metrics-apiserver TLS certs from a self-signed CA (replaces KEDA's built-in in-operator generator)
- KEDA `2.16.1` with operator + metrics-apiserver + admission-webhooks Prometheus endpoints enabled
- Prometheus + Alertmanager + kube-state-metrics + node-exporter
- Grafana `11` provisioned with dashboards for the monitoring stack, KEDA control-plane health, and demo CPU autoscaling
- KEDA-specific alert rules (component down, reconcile errors, adapter↔operator gRPC errors, scaler errors, demo HPA pinned at max, demo pods Pending)
- Two demo workloads — one with a CPU (resource) trigger, one with a Prometheus (external) trigger — so every KEDA metric path is exercised
- `keda-deprecation-webhook` (KDW) — a ValidatingWebhook + controller that blocks/inventories deprecated KEDA spec fields ahead of the 2.16 → 2.18 fleet upgrade (KEDA001 = cpu/memory `metadata.type`). Lab CM exempts the existing `legacy-cpu` namespace to `severity: warn`

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
make verify-webhook # E2E checks for keda-deprecation-webhook
make demo-deprecated# apply a deliberately-deprecated SO (expects KDW rejection)
```

## keda-deprecation-webhook (KDW)

A ValidatingWebhook + controller that blocks/inventories deprecated KEDA spec
fields ahead of the 2.16 → 2.18 fleet upgrade. KEDA001 (cpu/memory
`metadata.type`) is the first rule shipped.

- **Spec:** `docs/superpowers/specs/2026-05-05-keda-deprecation-webhook-design.md`
- **Plan:** `docs/superpowers/plans/2026-05-09-keda-deprecation-webhook.md`
- **操作手冊(繁中):** `docs/keda-deprecation-webhook-zh-TW.md`
- **Manifests:** `kdw/manifests/deploy/`
- **Lab CM** (`kdw/manifests/deploy/configmap.yaml`) defaults
  `KEDA001` to `severity: error` and exempts the `legacy-cpu` namespace to
  `severity: warn` so the existing deprecated SO demonstrates the warn-mode
  code path without being permanently blocked.
- **Reject-mode demo:** `make demo-deprecated` — applies a deliberately
  deprecated SO in the `demo-deprecated` namespace; expected to be rejected
  by the webhook with an explanatory message.
- **Dashboard:** Grafana → **KEDA Deprecations** (UID `keda-deprecations`).
- **Alerts:** `KedaDeprecationWebhookDown`, `KedaDeprecationConfigReloadFailing`,
  `KedaDeprecationErrorViolationsPresent` (group `keda-deprecations`).
- **E2E:** `make verify-webhook` — spins up an in-cluster curl pod, hits
  `/metrics`, exercises CREATE rejection in `demo-deprecated`, asserts the
  warn-mode gauge for `legacy-cpu`, and verifies the gauge series cleanup
  on a CM hot-reload that flips `legacy-cpu` to `severity: "off"`.

## Monitoring

### Prometheus targets

`lab/keda/values.yaml` enables `prometheus.<operator|metricServer|webhooks>.enabled`,
which makes the chart annotate the three KEDA Services with
`prometheus.io/scrape=true`. The upstream prometheus-community chart's
`kubernetes-service-endpoints` scrape job picks them up automatically.

Verify:

```bash
kubectl -n monitoring exec deploy/prometheus-server -c prometheus-server -- \
  wget -q -O - 'http://localhost:9090/api/v1/query?query=up{namespace="platform-keda"}'
```

You should see one healthy `up==1` target each for `keda-operator`,
`keda-operator-metrics-apiserver`, and `keda-admission-webhooks` under the
`kubernetes-service-endpoints` job.

> Dashboard queries do **not** pin the `job` label. The chart hardcodes
> a pod-level `prometheus.io/scrape="true"` annotation on the metrics-apiserver
> Deployment whenever `prometheus.metricServer.enabled=true`, which made the
> `kubernetes-pods` job scrape it on top of the canonical
> `kubernetes-service-endpoints` scrape and double-counted every gRPC client
> series. `lab/keda/values.yaml` overrides that pod annotation back to `"false"`
> so only one job scrapes each component, and queries can stay job-agnostic.

### Why two demo workloads

KEDA emits two distinct families of metrics depending on the trigger type:

| Trigger family | Examples | Path through KEDA | Metrics that populate |
| --- | --- | --- | --- |
| Resource (cpu, memory) | `lab/manifests/demo-cpu` | KEDA creates an HPA with a `Resource` metric source. metrics-server feeds the HPA directly — KEDA's adapter is **not** in the loop. | `keda_resource_registered_total`, `keda_scaled_object_*`, `controller_runtime_*`, `workqueue_*` |
| External (prometheus, kafka, ...) | `lab/manifests/demo-prom` | KEDA creates an HPA with an `External` metric source. The kube-apiserver routes that to KEDA's metrics-apiserver, which calls the operator over gRPC. | All of the above **plus** `keda_scaler_*` and `keda_internal_metricsservice_grpc_*` (server + client side) |

Both are deployed by `make demo` (and `make up`). The Prometheus-trigger
demo's query reads the cpu-demo's CPU usage, so a single
`make load-test` exercises both paths simultaneously and lights up every
panel on *KEDA Operations*.

### Grafana dashboards

Three dashboards are provisioned from `lab/grafana/dashboards/` (lab core) and `kdw/dashboard.json` (KDW):

| UID | Title | Use it for |
| --- | --- | --- |
| `monitoring-stack` | Monitoring Stack | Monitoring-only installs: Prometheus scrape health, Kubernetes node/pod inventory, node-exporter CPU/memory, and active target health. |
| `keda-operations` | KEDA Operations | KEDA control-plane health: pod up state, reconcile errors, reconcile latency, workqueue depth, component CPU/RAM, **adapter ↔ operator gRPC** traffic + latency, **external scaler** activity / latency / errors. |
| `keda-demo-cpu-scaling` | KEDA Demo - CPU Autoscaling | The cpu-demo workload: replicas (current vs desired vs min/max), per-pod CPU vs request, utilization vs the 50% trigger threshold, pod phases, zone spread, firing-alerts table. |

#### Template variables

Both dashboards expose three template variables in the top bar:

| Variable | Type | What it does |
| --- | --- | --- |
| `Datasource` | `datasource` | Picks which Prometheus to query — handy when you connect Grafana to multiple clusters. |
| `Prodsuite` | query | Filters which namespaces appear in the `Namespace` picker. Driven by the namespace label `prodsuite=<value>` exposed via kube-state-metrics. |
| `Namespace` | query, multi-select | Scopes every panel that filters by `namespace`. Defaults to `All` (every namespace under the chosen prodsuite). |

The lab labels:

| Namespace | `prodsuite` |
| --- | --- |
| `platform-keda` | `Platform` |
| `monitoring` | `Platform` |
| `demo-cpu` | `Demo` |
| `demo-prom` | `Demo` |
| `legacy-cpu` | `legacy` |

Add a label to any other namespace (`kubectl label ns foo prodsuite=Bar`) and
it shows up in the picker on next refresh — kube-state-metrics' allowlist
already includes the `prodsuite` key (see `lab/prometheus/values.yaml`).

#### Switching between clusters

Both dashboards expose a `datasource` template variable of type
`datasource` filtered to `prometheus`. The dropdown at the top of the
dashboard lists every Prometheus datasource Grafana knows about, so
viewing a different cluster is one click — no per-panel rewrites.

To wire in another cluster, add an entry to
`grafana/provisioning/datasources/prometheus.yaml` (the file ships an
example block) and re-run `make install-grafana`. The new entry will
appear in the picker on the next reload.

### Alerts

`lab/prometheus/values.yaml` ships three rule groups:

- `keda-control-plane` — `KedaOperatorDown`, `KedaMetricsApiServerDown`,
  `KedaAdmissionWebhooksDown`, `KedaReconcileErrors`, `KedaWorkqueueBacklog`,
  `KedaAdapterToOperatorGrpcErrors` (non-OK gRPC codes), and
  `KedaAdapterToOperatorGrpcSilence` — fires only when there was sustained
  adapter→operator traffic in the 10-minute window starting 15 minutes ago
  AND the most recent 5 minutes are completely silent. The offset window
  guarantees a fresh cluster that has never run an external-trigger
  ScaledObject does NOT fire this alert (no past traffic = precondition
  fails). It catches the cases that don't surface as RPC errors: mTLS
  cert expiry, a wedged operator, a network partition.
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
  node-exporter, Grafana, cert-manager, and KEDA, then deploys the CPU demo
  workload. cert-manager is installed by `lab/scripts/install-keda.sh` because
  KEDA's chart (`lab/keda/values.yaml`) routes its TLS through cert-manager.
- `make prepull-images` (also run automatically by `make up` after
  `create-cluster`) renders every chart with the same values the installer
  uses, dedupes the resulting `image:` references, `docker pull`s each one
  in parallel, and `kind load`s them into the cluster. This prevents
  `ImagePullBackOff` and shaves first-run install time. Local-only
  `dhi.io/...` images are skipped — they're loaded by their own install
  scripts via `load_docker_image_to_kind`.
- `make load-test` temporarily patches the demo container into a busy loop so
  KEDA can scale it up; it restores the idle command on exit.
- The `monitoring` namespace hosts Prometheus, Alertmanager, Grafana, and the
  metrics exporters. The `platform-keda` namespace hosts KEDA itself. The `demo-cpu`
  and `demo-prom` namespaces host the two demo workloads. The `legacy-cpu`
  namespace (`prodsuite=legacy`) hosts a workload using the **deprecated**
  CPU-trigger form (`metadata.type: Utilization`) — it's the known offender
  the `keda-deprecation-webhook` spec is designed to inventory and block.
- Helm values live next to the install scripts: `lab/keda/values.yaml`,
  `lab/prometheus/values.yaml`, `lab/grafana/values.yaml`. Edit those, then re-run the
  matching `make install-*` target — no full cluster recreate needed.
