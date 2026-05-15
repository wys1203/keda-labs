# KEDA Monitoring Guide for Workload Teams

This guide is written for workload teams who deploy `ScaledObjects` and `ScaledJobs` onto a platform-managed KEDA. It explains what you can observe about your scaling behavior, what alerts mean, and what to do when things go wrong.

**You own the workload; the platform team owns KEDA itself.** This guide focuses on signals visible from the workload side.

---

## What KEDA does on this platform

KEDA is the Kubernetes Event Driven Autoscaling operator. When you create a `ScaledObject`, you tell KEDA:
- "Watch this metric (CPU, memory, or an external signal like Prometheus/Kafka)."
- "Create an HPA that scales my Deployment when that metric breaches a threshold."
- "Keep the replica count between `minReplicaCount` and `maxReplicaCount`."

KEDA reconciles the HPA continuously as the metric changes. The HPA then drives the Deployment replica count. You do not touch the HPA directly — KEDA creates and owns it.

On this platform, KEDA is installed in the `platform-keda` namespace and runs 2 replicas for high availability. The metrics-apiserver component (which handles external triggers like Prometheus) also runs 2 replicas. **Your namespace is separate.** When something goes wrong, you'll check a Grafana dashboard to answer: "Is KEDA healthy?" and "Is my workload scaling?"

---

## The Grafana dashboards for you

Access Grafana via `make grafana` (opens `http://localhost:3000` with credentials `admin` / `admin`). All KEDA dashboards live in the **KEDA Lab** folder. Each dashboard has three filter buttons at the top:
- **Datasource** — picker for Prometheus instance
- **Prodsuite** — filter by namespace label `prodsuite` (typically `Demo`, `Platform`, `legacy`)
- **Namespace** — scoped to your chosen prodsuite

You don't need to clone or customize any of these. The Workload Inventory + Workload Detail dashboards are **scaler-agnostic** and built from per-HPA metrics that work uniformly for every trigger type the platform supports (cpu, memory, prometheus, nats-jetstream, redis, cron, metrics-api).

| Dashboard | UID | When to use |
|---|---|---|
| **KEDA Workload Inventory** | `keda-workload-inventory` | **Start here.** Find your ScaledObject in the main table, click into Detail. Shows the full catalog with trigger type, threshold, replicas, paused state, and recent errors. |
| **KEDA Workload Detail** | `keda-workload-detail` | Drill into one ScaledObject: current vs desired replicas, metric value vs threshold, plus scaler errors/latency for external triggers. Pick `Namespace` and `ScaledObject` from the template variables. |
| **KEDA Workload — CPU Deep View** | `keda-workload-cpu` | Extra detail for cpu/memory triggers: per-pod cAdvisor CPU usage vs the 50% trigger threshold, pod zone spread, currently-firing alerts. Useful when troubleshooting CPU scaling specifically. |
| **KEDA Operations** | `keda-operations` | Platform-team's KEDA control-plane health view. Use to confirm "is KEDA itself healthy?" before opening a support ticket. Look for `Operator UP`, `Metrics API Server UP`, `Admission Webhooks UP` to be green. |
| **KEDA Deprecations** | `keda-deprecations` | Track deprecations that will break on KEDA 2.18. Filter by your namespace to see violations in your workloads (see Section 4). |

### Click-through

The Inventory's main table has a clickable **ScaledObject** column. Clicking opens the Detail dashboard pre-filtered to that ScaledObject — no manual variable setup needed. Detail's header has return links to Inventory and the CPU Deep view.

### Why Detail's "Scaler Errors / Latency / Active State" row reads "No data" for cpu/memory

CPU and memory triggers bypass KEDA's external-scaler path entirely — the HPA reads cAdvisor metrics directly via metrics-server. Those three panels are populated only for external scalers (prometheus, nats-jetstream, redis, cron, metrics-api). When you select a cpu-trigger ScaledObject, "No data" there is correct, not a bug. For deeper CPU visibility, follow the header link to the CPU Deep View dashboard.

---

## What alerts you'll see (and what's your job vs the platform's)

The KEDA platform uses a **three-tier alert structure**. The key principle: **Tier 1 + 2 = platform's problem; Tier 3 = your problem.**

### Tier 1 — SLO burn-rate alerts (platform pager)

Four alerts, all critical or warning severity. These measure KEDA's overall service health via multi-window multi-burn-rate SLOs.

| Alert name | Severity | Meaning |
|---|---|---|
| `KedaPlatformReconcileBudgetBurnFast` | critical | KEDA's reconcile success is burning its error budget too fast (fast burn = budget gone in ~12h). Platform is paged. |
| `KedaPlatformReconcileBudgetBurnSlow` | warning | KEDA's reconcile success is degrading (slow burn = budget gone in ~28h). Platform team gets a ticket. |
| `KedaPlatformOperatorUpBudgetBurnFast` | critical | KEDA operator pod(s) crashed or are failing too many scrapes (fast burn on UP). Platform is paged. |
| `KedaPlatformOperatorUpBudgetBurnSlow` | warning | KEDA operator is flaky (slow burn on UP). Platform team gets a ticket. |

**As a workload owner:** If you see Tier 1 alerts firing, your scaling may be slow or broken because KEDA itself is degraded. Link the alert to your support ticket so the platform team knows.

### Tier 2 — Component-cause alerts (platform pager)

Thirteen alerts. These point to specific failure modes: a pod is down, the webhook is slow, the gRPC channel is broken, a certificate is about to expire, etc. All are `audience: platform` — they page the KEDA platform team, not you.

Common ones you may see:
- `KedaOperatorDown` / `KedaMetricsApiServerDown` — a required component is unreachable for 5m.
- `KedaAdmissionWebhookLatencyHigh` — `kubectl apply` of your `ScaledObject` is taking >1s on p99 (may hang if sustained >10s).
- `KedaContainerMemoryNearLimit` — KEDA pod memory is >90% of its limit; OOMKill is imminent. Platform needs to raise the limit.
- `KedaAdapterToOperatorGrpcErrors` or `KedaAdapterToOperatorGrpcSilence` — external-trigger path is broken; your Prometheus/Kafka triggers won't work.

**As a workload owner:** If you suspect KEDA is down or the webhook is slow, check KEDA Operations dashboard. If Tier 2 alerts are firing, open a ticket and include the alert name.

### Tier 3 — Observation alerts (no pager, info-only)

Seven alerts, all `severity: info`. **These never page anyone.** They appear on dashboards and during business hours review. Four of them are about *your* workload:

| Alert name | Audience | Meaning | Your action |
|---|---|---|---|
| `KedaScaledObjectErrors` | workload-owner | Your `ScaledObject` is reporting an error. | Check `kubectl describe scaledobject <name>` for the error. Likely a misconfigured trigger or bad credentials. |
| `KedaScalerErrors` | workload-owner | Your scaler (the component talking to your metric source) is hitting errors >0.1/s. | The external metric source (Prometheus, Kafka, etc.) is unreachable, slow, or rejecting your query. Check connectivity and credentials on your side. |
| `KedaScalerMetricsLatencyHigh` | workload-owner | Your external metric source is responding slowly (>1s p95). | Investigate why your Prometheus/Kafka/etc. is slow. May be a resource issue on your metric infrastructure. |
| `KedaScaledObjectAtMaxReplicas` | workload-owner | Your HPA is pinned at `maxReplicaCount` for 10+ minutes. | Either raise `maxReplicaCount` if demand is real, or lower your trigger threshold. You have headroom to tune. |

The other three (`KedaDeprecationErrorViolationsPresent`, `DemoCpuAtMaxReplicas`, `DemoCpuPodsPending`) are either fleet-wide deprecation inventory or lab-demo-only.

**Key point:** Tier 3 alerts are not your emergency — they are informational. They won't wake you up. But they tell you something about your workload behavior you should know.

---

## The deprecation webhook — what it means when you get `Forbidden`

KEDA 2.18 removes support for the old `triggers[].metadata.type` field on CPU/memory triggers. Before that version ships, a **deprecation webhook** (KDW) blocks new code from using the deprecated form.

### When you'll see it

You apply a `ScaledObject` with:

```yaml
triggers:
  - type: cpu
    metadata:
      type: Utilization      # ← deprecated
      value: "50"
```

You get back:

```
Error from server (Forbidden): admission webhook "vkdw.keda.sh" denied the request:
rejected by keda-deprecation-webhook:
  - [KEDA001] trigger[0] (type=cpu): metadata.type is deprecated since KEDA 2.10 and removed in 2.18
    — Use triggers[0].metricType: Utilization instead.
```

### How to fix it

Change `metadata.type` to `metricType` at the trigger level:

```yaml
triggers:
  - type: cpu
    metricType: Utilization    # ← correct (2.18-compatible)
    metadata:
      value: "50"
```

Apply again — it should succeed.

### Check your namespace for violations

Run:

```bash
kubectl get scaledobject -A -o json | jq '.items[] | select(.spec.triggers[]? | select(.metadata.type)) | {namespace: .metadata.namespace, name: .metadata.name}'
```

Or check the **KEDA Deprecations** dashboard panel #6 (table) filtered to your namespace.

For the full KDW operator manual (architecture, ConfigMap schema, enforcement levels), see `docs/keda-deprecation-webhook-zh-TW.md` (Traditional Chinese; English version is planned).

---

## Common situations and what to do

| Symptom | Where to look | What to do |
|---|---|---|
| **My HPA isn't scaling.** Replicas are stuck at min, no matter how high the metric goes. | KEDA Operations dashboard: verify `Operator UP` and `Metrics API Server UP` are green. Then: `kubectl get scaledobject <name> -n <ns>` and look for `READY=True` in the status. | If KEDA looks healthy, suspect your ScaledObject spec or the metric source. Check Tier 3 alerts `KedaScaledObjectErrors` and `KedaScalerErrors` for your namespace. Fix the error, reapply, and retry. |
| **My `kubectl apply` of a ScaledObject timed out or was rejected.** | The kubectl output contains the rule ID and fix hint (see Section 4). | If it's a deprecation rejection (KEDA001), apply the YAML fix. If it's a timeout, the admission webhook was slow — check `KedaAdmissionWebhookLatencyHigh` alert and open a platform ticket. |
| **I'm pinned at max replicas and can't scale higher.** | KEDA Demo dashboard (or your own clone) shows replicas == maxReplicaCount for 10+ min. | Raise `maxReplicaCount` in your ScaledObject if the demand is real. Or lower the trigger threshold (`value` in metadata) if you're being too aggressive. This is not a KEDA bug — it's tuning. |
| **My metric source (Prometheus, Kafka, etc.) is down.** | KEDA Operations dashboard under "Adapter ↔ Operator gRPC" or "External scalers" rows; or check Tier 3 `KedaScalerErrors` / `KedaScalerMetricsLatencyHigh`. | Fix your metric infrastructure. KEDA will resume scaling once the source is healthy. This is your responsibility, not the platform's. |
| **I see "admission webhook" in an error but it's not a deprecation.** | `kubectl apply` failed with a Forbidden error that doesn't mention KEDA001 or metadata.type. | Ask the platform team — it may be a different webhook or policy. Include the full error message and the rule name if shown. |

---

## Self-serve commands you'll actually run

```bash
# See all ScaledObjects across the cluster; READY should be True
kubectl get scaledobject -A

# Detailed status of your ScaledObject — shows conditions and recent errors
kubectl describe scaledobject <name> -n <your-namespace>

# See the HPA that KEDA created for your workload (named keda-hpa-<so-name>)
kubectl get hpa -n <your-namespace>

# Port-forward Grafana to localhost:3000 (admin/admin)
make grafana

# Port-forward Prometheus to localhost:9090 (for PromQL queries)
make prometheus

# See if any deprecated specs exist in your namespace
kubectl get scaledobject -n <your-namespace> -o json | jq '.items[] | select(.spec.triggers[]? | select(.metadata.type)) | .metadata.name'

# Watch logs of the deprecation webhook if applying a ScaledObject fails
kubectl logs -n keda-system -l app.kubernetes.io/name=keda-deprecation-webhook --tail=20 -f

# Trigger a demo of what rejection looks like (lab-only; will fail)
make demo-deprecated
```

---

## Opening a platform support ticket

When KEDA isn't working as expected and it's not something you can fix yourself:

**Include in your ticket:**
1. Your namespace and the name of your `ScaledObject` or `ScaledJob`.
2. Output of: `kubectl describe scaledobject <name> -n <namespace>`
3. A screenshot of the relevant **KEDA Operations** dashboard panel (e.g., operator UP, webhook latency).
4. The name of any firing alert and a link to it in Alertmanager (`make alertmanager`, `http://localhost:9093`). Include the timestamp and rule conditions.
5. Brief description of what you expected vs what happened (e.g., "Replicas should scale to 4, but are stuck at 1").

The platform team will use this to quickly diagnose whether the issue is in KEDA, your spec, or your metric source.

---

## How this guide relates to other docs

- **`docs/lab-overview.md`** — comprehensive reference for the entire lab, including architecture, alert ruleset, SLO definitions, and quickstart. Platform-team-oriented; more depth and internals.
- **`docs/superpowers/specs/2026-05-12-keda-platform-alerts-design.md`** — the design rationale behind the three-tier alert structure. For context on why certain alerts exist and how they interact.
- **`docs/superpowers/specs/2026-05-14-keda-workload-dashboards-design.md`** — the design rationale behind the Inventory + Detail + CPU Deep View dashboards (scaler-agnostic, no per-workload cloning).
- **`docs/keda-deprecation-webhook-zh-TW.md`** — KDW operator manual in Traditional Chinese. Covers the webhook's architecture, ConfigMap schema, multi-cluster rollout, and day-2 operations.

---

## Quick reference

| What you need | How to access it |
|---|---|
| See your HPA scaling in real time | Open **KEDA Workload Inventory**, find your ScaledObject in the table, click into Detail. |
| Check if KEDA is healthy | KEDA Operations dashboard, `Prodsuite=Platform`. Look for green on "Operator UP", "Metrics API Server UP", "Admission Webhooks UP". |
| Find out why your ScaledObject was rejected | Read the kubectl error message carefully. If it mentions `[KEDA001]`, it's a deprecation — apply the fix. Otherwise, open a platform ticket. |
| Track deprecation violations in your namespace | KEDA Deprecations dashboard, filter by your namespace. Panel #6 shows the table of violations. |
| See what Tier 3 workload alerts are firing for you | `/api/v1/alerts` in Prometheus, filter by `severity=info AND audience=workload-owner AND exported_namespace=<your-ns>`. Or check a custom dashboard you build. |
| Get help from the platform team | Open a ticket with: namespace, ScaledObject name, `kubectl describe` output, screenshot from dashboard, and the alert name if applicable. |
