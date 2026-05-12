# keda-platform-alerts — Design

**Status:** Draft (spec)
**Date:** 2026-05-12
**Owner:** wys1203
**Scope:** Prometheus rule changes in `lab/prometheus/values.yaml`. Alertmanager routing / inhibition is **out of scope** (separate spec).

---

## Context

The lab currently ships **23 alert rules** across 5 groups in `lab/prometheus/values.yaml`. They were authored incrementally without a unifying severity / audience policy, so platform operators face three concrete problems:

1. **Overlap pages.** SLO burn-rate alerts (`KedaPlatform*BudgetBurnFast/Slow`) and raw threshold alerts (`KedaReconcileErrors`) fire on the same condition, just with different thresholds. One incident becomes two pages.
2. **Audience mixing.** Workload-owner concerns (`DemoCpuAtMaxReplicas`, `KedaScaledObjectAtMaxReplicas`, `KedaScalerErrors`) live in the same `keda-scalers` group as platform-team concerns (`KedaOperatorLeaderChurn`, `KedaCertNearExpiry`). All carry `severity: warning`, training operators to ignore them.
3. **Jumpy thresholds.** `KedaDeprecationConfigReloadFailing` is `for: 0m` — fires on the first transient parse glitch, regardless of whether it self-recovers.

The goal of this spec is to make every alert answer the question **"who fixes this and how urgent is it?"** explicitly, and to demote signals that don't pass that bar to dashboard-only `info`.

## Goals

- Every alert ends up in one of three tiers with a written rule for what each tier means.
- Every alert carries four labels: `severity`, `tier`, `component`, `audience`.
- Workload-owner signals never enter the platform pager.
- Specific causes that the SLO can't pinpoint are kept as warnings (with `for:` durations tuned to suppress flap), not collapsed into SLO.
- Two specific gaps in platform coverage are filled: admission webhook latency and KEDA container memory pressure.

## Non-goals

- Alertmanager routing tree, receivers, and inhibition rules. These will be a follow-on spec — labels in this spec are designed for that downstream use.
- Workload-owner pager / Slack routing. Workload alerts are kept as `info` here; how they fan out to tenant teams is downstream.
- KDW (`keda-deprecation-webhook`) emitting its own admission-latency histogram. Out of scope; KDW's webhook is lightweight (lint is microseconds) and not currently a latency risk.
- Touching the demo workload alert group's existence. We re-tag them as `audience: lab-only`; we don't drop them, so `make verify-webhook` and the lab's regression scripts that look for these alert names keep working.

## Constraints

- Lab Kubernetes `1.24.17`, Prometheus from `prometheus-community/prometheus` Helm chart, KEDA `2.16.1`, `keda-deprecation-webhook` from the same repo. The exact metric names available are constrained by these versions.
- All rules live in a single `lab/prometheus/values.yaml` under `serverFiles.alerting_rules.yml.groups`. Helm chart doesn't expose a clean "multiple files merged" knob, so we don't split across files.

---

## Architecture

### Label conventions

Every alert in the resulting ruleset carries these four labels:

```yaml
labels:
  severity: critical | warning | info
  tier:     "1" | "2" | "3"
  component: keda-operator
           | keda-metrics-apiserver
           | keda-admission-webhooks
           | keda-deprecation-webhook
           | cert-manager
           | workload
  audience: platform | workload-owner | lab-only
```

`tier` is the **structural classification** of the signal. `severity` is the **routing urgency**. They are correlated but not equivalent:

| tier | meaning | allowed severities |
|---|---|---|
| **1** | SLO macro signal — KEDA's overall service health | `critical` (fast burn) or `warning` (slow burn) |
| **2** | Specific platform cause / measurement failure — SLO can't pinpoint or is unmeasurable | `critical` or `warning` |
| **3** | Observation signal — workload-owner concern or lab-only debug | `info` only |

`audience` is used by Alertmanager (downstream spec) to pick the receiver. Tier 1 + 2 alerts are always `audience: platform`. Tier 3 is `audience: workload-owner` except for the two `demo-cpu-workload` rules which are `audience: lab-only`.

### The three tiers

```
                  Tier 1 — SLO burn-rate
                  ──────────────────────
                  4 alerts, multi-window
                  multi-burn-rate.
                  Fast → pager (critical)
                  Slow → ticket (warning)
                          │
                          ▼ informs
                  Tier 2 — Component cause
                  ────────────────────────
                  13 alerts, specific
                  failure modes /
                  measurement failures.
                  critical or warning.
                          │
                          ▼ may shadow
                  Tier 3 — Observation (info only)
                  ────────────────────────────────
                  7 alerts, never page.
                  Dashboard / business-hours.
                  audience = workload-owner | lab-only
```

Top-down dependency: a Tier 1 fire generally has a Tier 2 cause that fired earlier (or would have, on a slightly different metric). Tier 3 is *informational* — it never causes Tier 1 or 2 to fire and is never used as a routing signal beyond the dashboards.

---

## Per-alert audit

The 23 existing alerts are reclassified as follows.

### Tier 1 — SLO burn-rate (4, all kept unchanged)

| Alert | severity | for | Action |
|---|---|---|---|
| `KedaPlatformReconcileBudgetBurnFast` | critical | 2m | Keep; add labels |
| `KedaPlatformReconcileBudgetBurnSlow` | warning  | 15m | Keep; add labels |
| `KedaPlatformOperatorUpBudgetBurnFast` | critical | 2m | Keep; add labels |
| `KedaPlatformOperatorUpBudgetBurnSlow` | warning  | 15m | Keep; add labels |

Why unchanged: multi-window multi-burn-rate is the canonical noise-resistant SLO alert pattern. Expressions and thresholds are sound. Only the label set grows (`tier`, `component`, `audience`).

### Tier 2 — Component cause (13; 11 kept from existing + 2 new)

#### Kept from existing (9)

| Alert | severity | for | Δ | Why kept as platform pager |
|---|---|---|---|---|
| `KedaOperatorDown` | critical | 5m | unchanged | `absent(up==1)` covers the case where SLO becomes NaN because targets vanish |
| `KedaMetricsApiServerDown` | critical | 5m | unchanged | Same role for the metrics-apiserver |
| `KedaAdmissionWebhooksDown` | warning  | 10m | unchanged | `failurePolicy=Ignore` means apply still works — warning, not critical |
| `KedaAdapterToOperatorGrpcSilence` | critical | 5m | unchanged | Pre-existed traffic and stopped → pathological state inside KEDA |
| `KedaAdapterToOperatorGrpcErrors` | warning  | 5m | unchanged | gRPC error rate; SLO may not catch low-but-persistent rates |
| `KedaWorkqueueBacklog` | warning  | 10m | unchanged | Controller backing up; SLO sees only the eventual outcome |
| `KedaContainerCpuThrottling` | warning  | 10m | unchanged | KEDA pod being CPU-throttled by the kubelet |
| `KedaOperatorLeaderChurn` | warning  | 5m | unchanged | Leader election flapping |
| `KedaCertNearExpiry` | warning  | 1h | unchanged | cert-manager failed to renew (≤ 14 days) |

#### Kept from existing with tuning (1)

| Alert | severity | for | Δ | Why tune |
|---|---|---|---|---|
| `KedaDeprecationConfigReloadFailing` | warning | **5m** ← was 0m | `for` bumped 0m → 5m | A single transient parse error shouldn't page. The webhook already keeps the last good config on parse failure, so a 5-minute persistent failure is the real signal |

#### Kept from existing (KDW group, 1)

| Alert | severity | for | Δ | Why platform pager |
|---|---|---|---|---|
| `KedaDeprecationWebhookDown` | critical | 5m | unchanged | KDW is platform's responsibility; webhook failure is `failurePolicy: Ignore` (apply slips through) so SLO won't catch — needs its own critical |

#### New (2)

##### `KedaAdmissionWebhookLatencyHigh`

```yaml
- alert: KedaAdmissionWebhookLatencyHigh
  expr: |
    histogram_quantile(0.99,
      sum by (le) (
        rate(controller_runtime_webhook_request_duration_seconds_bucket{
          app_kubernetes_io_name="keda-admission-webhooks"
        }[5m])
      )
    ) > 1
  for: 10m
  labels:
    severity: warning
    tier: "2"
    component: keda-admission-webhooks
    audience: platform
  annotations:
    summary: KEDA admission webhook p99 latency > 1s for 10m
    description: |
      apiserver applies a 10-second timeout to admission webhooks; p99 > 1s
      means callers are starting to feel kubectl apply latency. SLO catches
      `up==0` cases but not "up and slow". Investigate KEDA operator pod
      resources, leader election state, and downstream metrics-apiserver
      health.
```

Why: apiserver's admission timeout is 10s; once p99 climbs past 1s, callers experience visible `kubectl apply` lag. The SLO does **not** cover this (it only measures `up` and reconcile-error ratio, not webhook latency). Required metric `controller_runtime_webhook_request_duration_seconds` is exported by default by controller-runtime — **verification step required** during implementation: confirm the histogram appears in Prometheus before enabling this alert.

##### `KedaContainerMemoryNearLimit`

```yaml
- alert: KedaContainerMemoryNearLimit
  expr: |
    max by (pod, container) (
      container_memory_working_set_bytes{namespace="platform-keda", container!="", container!="POD"}
      /
      container_spec_memory_limit_bytes{namespace="platform-keda", container!="", container!="POD"}
    ) > 0.9
  for: 15m
  labels:
    severity: warning
    tier: "2"
    component: keda-operator
    audience: platform
  annotations:
    summary: KEDA container {{ $labels.pod }}/{{ $labels.container }} > 90% memory limit for 15m
    description: |
      KEDA's working set has been above 90% of its memory limit for 15
      minutes. OOMKill is imminent; SLO will degrade after the kill, but
      this signal lets platform raise the limit (or investigate a leak)
      before the outage. CPU throttling already has its own alert; memory
      is the symmetric gap.
```

Why: complements the existing `KedaContainerCpuThrottling`. Memory pressure leads to OOMKill which the SLO eventually catches as a budget burn; the alert exists to give a 15-minute lead time. cAdvisor exposes both metrics by default.

### Tier 3 — Observation (7, all demoted to `severity: info`)

All seven keep their existing PromQL expressions and `for:` durations unchanged. The only change is `severity` (warning → info), the new label set, and `audience` reclassification.

| Alert | original sev | new sev | new audience | Rationale |
|---|---|---|---|---|
| `KedaScaledObjectErrors` | warning | **info** | workload-owner | Per-SO scaler errors — workload's scaler config or its external dep |
| `KedaScalerErrors` | warning | **info** | workload-owner | Per-scaler errors — workload concern |
| `KedaScalerMetricsLatencyHigh` | warning | **info** | workload-owner | Latency to workload's external metric source — workload concern |
| `KedaScaledObjectAtMaxReplicas` | warning | **info** | workload-owner | Workload reached its own `maxReplicaCount` ceiling |
| `KedaDeprecationErrorViolationsPresent` | warning | **info** | workload-owner | Inventory of error-severity deprecations across the fleet — debt list, not an outage |
| `DemoCpuAtMaxReplicas` | warning | **info** | lab-only | Demo workload behavior — must not bleed into production view |
| `DemoCpuPodsPending` | warning | **info** | lab-only | Same |

### Dropped (1)

| Alert | Why dropped |
|---|---|
| `KedaReconcileErrors` | Measures the same thing as `KedaPlatformReconcile*BudgetBurn{Fast,Slow}` (controller-runtime reconcile error rate). The two were independent thresholds on the same SLI. The SLO version is multi-window multi-burn-rate (suppresses flap); the raw threshold is not. Keep the better-designed alert. |

---

## Final group layout

After this spec lands, `lab/prometheus/values.yaml`'s `serverFiles.alerting_rules.yml.groups` will look like:

```yaml
groups:
  - name: stdout-sink
    rules: [...]                # unchanged, not a KEDA alert
  - name: keda-platform-slo
    rules: [...]                # 4 alerts (Tier 1), labels updated
  - name: keda-control-plane
    rules: [...]                # 9 alerts (Tier 2) — was 8, +2 new, -1 dropped
                                #   removed: KedaReconcileErrors
                                #   added:   KedaAdmissionWebhookLatencyHigh
                                #            KedaContainerMemoryNearLimit
  - name: keda-deprecations
    rules: [...]                # 3 alerts (2 Tier 2 + 1 Tier 3)
                                #   KedaDeprecationConfigReloadFailing: for 0m → 5m
                                #   KedaDeprecationErrorViolationsPresent: sev warn → info
  - name: keda-workloads        # ← renamed from keda-scalers
    rules: [...]                # 4 alerts (Tier 3 info-only)
                                #   KedaScaledObjectErrors / KedaScalerErrors /
                                #   KedaScalerMetricsLatencyHigh /
                                #   KedaScaledObjectAtMaxReplicas
  - name: lab-demo              # ← renamed from demo-cpu-workload
    rules: [...]                # 2 alerts (Tier 3 info, audience=lab-only)
                                #   DemoCpuAtMaxReplicas / DemoCpuPodsPending
```

Group renames make the audience visible at a glance:
- `keda-scalers` → `keda-workloads` (these are tenant-workload signals, not "scalers as a component")
- `demo-cpu-workload` → `lab-demo` (already isolated; now named accordingly)

The unrelated alerts (`KedaOperatorLeaderChurn`, `KedaCertNearExpiry`) move from `keda-scalers` into `keda-control-plane` where they actually belong — they were misplaced.

### Numeric summary

| Tier | Before | After |
|---|---|---|
| 1 (SLO) | 4 | 4 |
| 2 (component) | 8 | 13 |
| 3 (info-only) | 0 | 7 |
| Group-routed (existing severity warning, no tier) | 11 | 0 |
| Dropped | — | 1 |
| Added | — | 2 |
| **Total alerts** | 23 | 24 |

Sanity arithmetic: `23 − 1 (drop) + 2 (add) = 24` final alerts. Tier breakdown: 4 + 13 + 7 = 24. ✓

---

## Failure modes (this spec's own assumptions)

| Scenario | Mitigation |
|---|---|
| `controller_runtime_webhook_request_duration_seconds` doesn't exist in the lab's Prometheus | Verification step in the implementation plan must confirm presence before enabling `KedaAdmissionWebhookLatencyHigh`. If absent, defer that alert and ship the rest |
| `container_spec_memory_limit_bytes` returns 0 (no limit set on KEDA pod) | The expression divides by 0, returns +Inf which is > 0.9 → alert fires forever. Lab's `lab/keda/values.yaml` does set a memory limit; if a future operator removes it, the alert silently breaks. Mitigation: pin a numeric `_or vector(0)` clamp on the denominator? Decision: rely on the values.yaml convention; add a comment in the rule pointing to this risk |
| Tier 3 `info` rules still create burden through `/api/v1/alerts` API noise on dashboards | Acceptable — they're filtered at the dashboard layer (panel queries can filter on `severity=~"critical\|warning"`) |
| Operators leave `severity: info` rules to silently rot | Detection: the existing keda-deprecations dashboard already shows the violations gauge; Tier 3 alerts are second-line observation. The Tier 3 rules don't need active maintenance |
| New `for: 5m` on `KedaDeprecationConfigReloadFailing` masks a real persistent failure for 5 extra minutes | Acceptable trade — the webhook is still using the previous good config during that window, so admission decisions are not wrong |

---

## Testing strategy

Three levels. All run against the live lab cluster.

### Level 1 — Syntax

```bash
helm template prometheus prometheus-community/prometheus \
  -f lab/prometheus/values.yaml \
  | yq '.[] | select(.kind=="ConfigMap" and .metadata.name == "prometheus-server") .data["alerting_rules.yml"]' \
  > /tmp/alerting_rules.yml
promtool check rules /tmp/alerting_rules.yml
```

Expect: `SUCCESS: <N> rules found`.

### Level 2 — Loaded by Prometheus

```bash
make install-prometheus
sleep 5
kubectl -n monitoring port-forward svc/prometheus-server 9090:80 &
curl -s http://localhost:9090/api/v1/rules \
  | jq -r '.data.groups[].rules[] | select(.type=="alerting") | .name' \
  | sort > /tmp/loaded-alerts.txt
diff /tmp/loaded-alerts.txt - <<'EOF'
DemoCpuAtMaxReplicas
DemoCpuPodsPending
KedaAdapterToOperatorGrpcErrors
KedaAdapterToOperatorGrpcSilence
KedaAdmissionWebhookLatencyHigh
KedaAdmissionWebhooksDown
KedaCertNearExpiry
KedaContainerCpuThrottling
KedaContainerMemoryNearLimit
KedaDeprecationConfigReloadFailing
KedaDeprecationErrorViolationsPresent
KedaDeprecationWebhookDown
KedaMetricsApiServerDown
KedaOperatorDown
KedaOperatorLeaderChurn
KedaPlatformOperatorUpBudgetBurnFast
KedaPlatformOperatorUpBudgetBurnSlow
KedaPlatformReconcileBudgetBurnFast
KedaPlatformReconcileBudgetBurnSlow
KedaScaledObjectAtMaxReplicas
KedaScaledObjectErrors
KedaScalerErrors
KedaScalerMetricsLatencyHigh
KedaWorkqueueBacklog
EOF
```

Expect: no diff. `KedaReconcileErrors` MUST NOT appear in loaded list.

### Level 3 — Behavioral spot-checks (one per tier)

**Tier 1:**
```bash
kubectl -n platform-keda scale deploy/keda-operator --replicas=0
# wait 2-3 minutes
curl -s http://localhost:9090/api/v1/alerts \
  | jq '.data.alerts[] | select(.labels.alertname=="KedaPlatformOperatorUpBudgetBurnFast") | .state'
# Expect: "firing"
kubectl -n platform-keda scale deploy/keda-operator --replicas=2   # restore
```

**Tier 2:**
```bash
kubectl -n keda-system patch cm keda-deprecation-webhook-config \
  --type merge -p '{"data":{"config.yaml":"INVALID :::: yaml"}}'
# wait 6 minutes (for: 5m)
curl -s http://localhost:9090/api/v1/alerts \
  | jq '.data.alerts[] | select(.labels.alertname=="KedaDeprecationConfigReloadFailing") | .state'
# Expect: "firing"
kubectl apply -f kdw/manifests/deploy/configmap.yaml   # restore
```

**Tier 3:**
```bash
# Verify that an info-tier alert exists in inactive state but doesn't get
# routed (no severity=warning|critical):
curl -s http://localhost:9090/api/v1/rules \
  | jq '.data.groups[].rules[] | select(.name=="KedaScaledObjectErrors") | .labels'
# Expect: {"severity":"info", "tier":"3", "component":"workload", "audience":"workload-owner"}
```

### Level 4 — Verification metric availability (gates the 2 new alerts)

Before turning on the two new alerts, sanity-check the source metrics exist:

```bash
curl -s "http://localhost:9090/api/v1/query?query=controller_runtime_webhook_request_duration_seconds_count{app_kubernetes_io_name=\"keda-admission-webhooks\"}" | jq '.data.result | length'
# Expect: > 0
curl -s "http://localhost:9090/api/v1/query?query=container_spec_memory_limit_bytes{namespace=\"platform-keda\"}" | jq '.data.result | length'
# Expect: > 0
```

If either returns 0, that alert is deferred — the implementation plan will document this as a gating step.

---

## Implementation footprint

This is a single-file refactor (`lab/prometheus/values.yaml`) plus a documentation update.

| File | Change |
|---|---|
| `lab/prometheus/values.yaml` | All rule edits; group renames; label additions; 1 alert dropped; 2 alerts added |
| `docs/lab-overview.md` | "Alert rules" section — refresh the per-group table (numeric summary above) |
| `README.md` | Bullet under "KEDA-specific alert rules" can stay (still accurate at the high level) — no edit needed |
| `docs/keda-deprecation-webhook-zh-TW.md` | §5.2 alert table — update `KedaDeprecationConfigReloadFailing` to `for: 5m` and `KedaDeprecationErrorViolationsPresent` to `severity: info` |

No Go code, no manifest changes outside Prometheus, no Helm chart override needed. The change is mechanical and reviewable as a diff.

---

## Out of scope / future work

- **Alertmanager routing tree**: the labels in this spec (`severity`, `tier`, `audience`) are designed to drive a downstream routing config (`receiver: platform-pager` for `severity=critical AND audience=platform`, etc.). Not in this spec.
- **Inhibition rules**: e.g., when `KedaOperatorDown` fires, suppress `KedaWorkqueueBacklog` and `KedaContainerCpuThrottling`. Alertmanager-side; downstream.
- **KDW admission-latency histogram**: KDW would need to emit `controller_runtime_webhook_request_duration_seconds` (or equivalent) before we can add a `KedaDeprecationWebhookLatencyHigh` alert. Future code change.
- **Multi-cluster fleet rollout**: this spec assumes a single Prometheus instance (the lab). Fleet rollout via GitOps is the standard k8s pattern and not specific to KEDA — out of scope here.
