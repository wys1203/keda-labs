# keda-workload-dashboards — Design

**Status:** Draft (spec)
**Date:** 2026-05-14
**Owner:** wys1203
**Scope:** New Grafana dashboards + rename of one existing dashboard + targeted updates to two docs. No Prometheus rule changes; no code changes.

---

## Context

Workload teams (tenants) deploy `ScaledObject`/`ScaledJob` onto the platform-managed KEDA. Today they have two problems:

1. **No inventory.** "Which ScaledObjects use the `metrics-api` scaler?" has no 1-click answer. KEDA Operations dashboard shows "trigger types in use" as an aggregate counter but doesn't break it down per ScaledObject.
2. **Per-workload monitoring guidance is wrong.** The user guide (PR #10) tells tenants to "duplicate the CPU demo dashboard and customize for your workload". That requires every team to reinvent dashboards, and the demo dashboard is structurally only useful for cpu triggers.

This spec replaces that guidance with two **scaler-agnostic** dashboards that work for all 7 scaler types in production use: `cpu`, `memory`, `prometheus`, `nats-jetstream`, `redis`, `cron`, `metrics-api`. The existing CPU demo dashboard is kept as a deeper view for cpu/memory triggers specifically (because cAdvisor data is rich and worth showing).

## Goals

- One dashboard that answers "what ScaledObjects exist in this namespace and what triggers do they use?"
- One dashboard that answers "for this one ScaledObject, what's it doing right now and over time?"
- Both work for all 7 trigger types using the same panels — no per-scaler customization.
- Click-through navigation: pick an SO in the inventory, drill into the detail.
- Existing CPU demo dashboard rephrased as a deeper view (kept as `keda-workload-cpu`).
- User guide §2 ("dashboards") rewritten to point users at the new dashboards instead of telling them to clone.

## Non-goals

- Per-scaler dashboards (e.g. one per `nats-jetstream`, one per `prometheus`). Maintenance cost grows linearly with scaler types and the underlying metrics are uniform; this approach is rejected as YAGNI.
- Custom Grafana plugins or panel types.
- Alertmanager routing changes (separate spec).
- Adding new Prometheus rules.
- Custom-resource-state-metrics or any new scraper configuration.
- Visualizing per-workload Prometheus query semantics (workloads own that on their own source dashboards; this work shows only KEDA's view of the metric value vs threshold).

## Constraints

- Lab Kubernetes `1.24.17`, Grafana 11, `prometheus-community/prometheus` chart, KEDA `2.16.1`.
- Dashboards are JSON files in `lab/grafana/dashboards/`, baked into the `grafana-dashboards` ConfigMap by `lab/scripts/install-grafana.sh`, mounted into the Grafana pod. Per `project_grafana_configmap_provisioning.md` memory: editing a file alone doesn't propagate — `make install-grafana` recreates the CM and rolls Grafana.
- All dashboards use the existing template variable convention: `Datasource`, `Prodsuite`, `Namespace`. Detail and CPU views additionally use `ScaledObject`.

## Key metric source mapping

A critical finding during exploration: **`keda_scaler_*` metrics only emit for external scalers**. CPU/memory triggers use the HPA Resource source path and bypass KEDA's adapter entirely.

So inventory and detail must combine two metric sources:

| Source | Covers | Used for |
|---|---|---|
| `kube_horizontalpodautoscaler_*` from kube-state-metrics, filtered `horizontalpodautoscaler=~"keda-hpa-.*"` | **All** triggers (cpu, memory, external) | Backbone of inventory; replica state + threshold + scaleTargetRef |
| `keda_scaler_*` from KEDA operator, label `exported_namespace` | **External** scalers only | Per-scaler active state, error rate, fetch latency, raw scaler view |

The HPA labels confirmed on the live lab:
- `kube_horizontalpodautoscaler_info` → `namespace`, `horizontalpodautoscaler`, `scaletargetref_kind`, `scaletargetref_name`
- `kube_horizontalpodautoscaler_spec_target_metric` → `metric_name` (`cpu` / `memory` / `s0-prometheus` / `s0-nats-jetstream` / etc.), `metric_target_type` (`utilization` / `average` / `value`), value = threshold
- `kube_horizontalpodautoscaler_spec_min_replicas`, `spec_max_replicas`, `status_current_replicas`, `status_desired_replicas`, `status_target_metric` → replica & current-value state

For trigger types, the `metric_name` label has the regex pattern `^s\d+-(.+)$` for external triggers (KEDA names them by scaler index), and the bare strings `cpu` or `memory` for resource triggers. A `label_replace` extracts the clean type.

---

## Architecture

Three Grafana dashboards under `lab/grafana/dashboards/`, all under the "KEDA Lab" Grafana folder, all using the canonical `Datasource` / `Prodsuite` / `Namespace` template variables. Cross-links between them via Grafana data-link URLs.

| File | UID | Title | Source |
|---|---|---|---|
| `keda-workload-inventory.json` | `keda-workload-inventory` | KEDA Workload Inventory | **NEW** |
| `keda-workload-detail.json` | `keda-workload-detail` | KEDA Workload Detail | **NEW** |
| `keda-workload-cpu.json` | `keda-workload-cpu` | KEDA Workload — CPU Deep View | **RENAMED** from `keda-demo-cpu-scaling.json` (UID + title + file). Query content unchanged — already uses `$namespace` template var, just changes default value from `demo-cpu` to `All`. |

The other existing dashboards (`keda-operations`, `keda-platform-slo`, `monitoring-stack`, and the remotely-fetched `keda-deprecations`) are untouched.

### Cross-navigation

- **Inventory → Detail**: the ScaledObject column has a Grafana data link → opens Detail dashboard with `var-Namespace` and `var-ScaledObject` pre-filled from the clicked row.
- **Inventory → CPU Deep**: rendered as a separate column (or row hover action) only when the row's trigger type is `cpu` or `memory`. Falls back to a header link if conditional column rendering isn't worth the JSON complexity.
- **Detail / CPU dashboard header**: contains "← Back to Inventory" link.

### Provisioning path (unchanged)

`lab/scripts/install-grafana.sh` does `kubectl create configmap grafana-dashboards --from-file=lab/grafana/dashboards`. Adding files to the directory + re-running the script (or `make install-grafana`) picks them up automatically. No script edits needed.

---

## Inventory dashboard panels

**Layout (24-column grid):**

```
Row 1 (h=4): [Total SOs w=6] [At Max w=6] [Paused w=6] [With Errors 1h w=6]
Row 2 (h=10): [Main Inventory Table w=24]
Row 3 (h=6):  [Trigger Type Distribution (pie) w=12] [Active External Scalers Timeline w=12]
Row 4 (h=6):  [Recent Errors Table w=24]
```

### Row 1 — Stat panels

| Stat | Query |
|---|---|
| **Total ScaledObjects** | `count(kube_horizontalpodautoscaler_info{horizontalpodautoscaler=~"keda-hpa-.*", namespace=~"$namespace"})` |
| **Pinned at Max** | `count((kube_horizontalpodautoscaler_status_current_replicas{horizontalpodautoscaler=~"keda-hpa-.*", namespace=~"$namespace"} == on(namespace, horizontalpodautoscaler) kube_horizontalpodautoscaler_spec_max_replicas{horizontalpodautoscaler=~"keda-hpa-.*", namespace=~"$namespace"}) > 0)` |
| **Paused** | `count(keda_scaled_object_paused{exported_namespace=~"$namespace"} == 1) or vector(0)` |
| **With Errors 1h** | `count(increase(keda_scaled_object_errors_total{exported_namespace=~"$namespace"}[1h]) > 0) or vector(0)` |

`or vector(0)` ensures the panel reads `0` rather than `No data` for empty result sets.

### Row 2 — Main Inventory Table

Backbone of the dashboard. Built from four parallel queries merged via Grafana table transformations on join keys `namespace` + `horizontalpodautoscaler` (for HPA metrics) and `exported_namespace` + `scaledObject` (for KEDA metrics).

```promql
# Query A — trigger + threshold (multiple rows per multi-trigger SO)
kube_horizontalpodautoscaler_spec_target_metric{horizontalpodautoscaler=~"keda-hpa-.*", namespace=~"$namespace"}

# Query B — scaleTargetRef
kube_horizontalpodautoscaler_info{horizontalpodautoscaler=~"keda-hpa-.*", namespace=~"$namespace"}

# Query C — replica state (one query each, four series)
kube_horizontalpodautoscaler_spec_min_replicas{horizontalpodautoscaler=~"keda-hpa-.*", namespace=~"$namespace"}
kube_horizontalpodautoscaler_status_current_replicas{horizontalpodautoscaler=~"keda-hpa-.*", namespace=~"$namespace"}
kube_horizontalpodautoscaler_status_desired_replicas{horizontalpodautoscaler=~"keda-hpa-.*", namespace=~"$namespace"}
kube_horizontalpodautoscaler_spec_max_replicas{horizontalpodautoscaler=~"keda-hpa-.*", namespace=~"$namespace"}

# Query D — KEDA-side paused state and error count
keda_scaled_object_paused{exported_namespace=~"$namespace"}
increase(keda_scaled_object_errors_total{exported_namespace=~"$namespace"}[1h])
```

Column transformations (Grafana table panel):

| Display column | Source field / derivation |
|---|---|
| **Namespace** | `namespace` |
| **ScaledObject** | strip prefix `keda-hpa-` from `horizontalpodautoscaler` (Grafana value-mapping or "rename by regex" transform) |
| **Target** | `scaletargetref_kind`/`scaletargetref_name` joined |
| **Trigger Type** | regex on `metric_name`: capture `^s\d+-(.+)$` → group 1 (`prometheus`, `nats-jetstream`, etc.); else passthrough (`cpu`, `memory`) |
| **Target Type** | `metric_target_type` |
| **Threshold** | value of `kube_horizontalpodautoscaler_spec_target_metric` |
| **Min** / **Cur** / **Des** / **Max** | the four replica metrics |
| **Paused** | `keda_scaled_object_paused` joined by `(exported_namespace, scaledObject)` — value mapping: 1=⏸ red, 0=blank |
| **Errors 1h** | `increase(keda_scaled_object_errors_total[1h])` joined; cell color: amber if > 0 |

**Data link on ScaledObject column**: `/d/keda-workload-detail/keda-workload-detail?var-Namespace=${__data.fields.Namespace}&var-ScaledObject=${__data.fields.ScaledObject}`.

### Row 3a — Trigger Type Distribution (pie)

```promql
count by (trigger_type) (
  label_replace(
    kube_horizontalpodautoscaler_spec_target_metric{horizontalpodautoscaler=~"keda-hpa-.*", namespace=~"$namespace"},
    "trigger_type", "$1", "metric_name", "^s\\d+-(.+)$"
  )
)
```

`label_replace` extracts the external-scaler suffix (e.g. `prometheus` from `s0-prometheus`); cpu/memory rows pass through unchanged because no `s\d+-` prefix matches. Pie chart legend shows scaler types in descending share.

### Row 3b — Active External Scalers Timeline

```promql
sum by (scaler) (keda_scaler_active{exported_namespace=~"$namespace"})
```

Time series stacked by `scaler` label. Panel title: "Active external scalers". Subtitle clarifies that cpu/memory triggers do not appear here (they bypass the KEDA adapter).

### Row 4 — Recent Errors Table

```promql
topk(20,
  increase(keda_scaled_object_errors_total{exported_namespace=~"$namespace"}[1h])
) > 0
```

Columns: namespace, scaledObject, errors_in_1h. Sorted descending. Empty table = healthy (good news).

---

## Detail dashboard panels

Template variables: `Datasource`, `Prodsuite`, `Namespace`, **`ScaledObject`** (single-select). The `ScaledObject` var holds the bare SO name (no `keda-hpa-` prefix) so user-facing display matches what they typed in their YAML.

`ScaledObject` template var query:
```promql
label_values(
  kube_horizontalpodautoscaler_info{horizontalpodautoscaler=~"keda-hpa-.*", namespace=~"$namespace"},
  horizontalpodautoscaler
)
```
With regex `/keda-hpa-(.+)/` capturing the SO name as the value.

**Layout:**

```
Row 1 (h=3): [Current w=4] [Desired w=4] [Min w=4] [Max w=4] [Active Triggers w=4] [Paused w=4]
Row 2 (h=9): [Replica History w=24]
Row 3 (h=8): [Metric Value vs Threshold w=12] [Trigger Detail Table w=12]
Row 4 (h=6): [Scaler Errors w=8] [Fetch Latency p95 w=8] [Active State Timeline w=8]
```

Row 4 always shows; for cpu/memory-only SOs the panels render "No data" — that's an accurate truth, not an error. (Trying to conditionally hide based on query-returns-data introduced too much JSON complexity for marginal value.)

### Row 1 — Stats

| Stat | Query |
|---|---|
| **Current Replicas** | `kube_horizontalpodautoscaler_status_current_replicas{namespace="$namespace", horizontalpodautoscaler="keda-hpa-$ScaledObject"}` |
| **Desired** | `kube_horizontalpodautoscaler_status_desired_replicas{namespace="$namespace", horizontalpodautoscaler="keda-hpa-$ScaledObject"}` |
| **Min** | `kube_horizontalpodautoscaler_spec_min_replicas{namespace="$namespace", horizontalpodautoscaler="keda-hpa-$ScaledObject"}` |
| **Max** | `kube_horizontalpodautoscaler_spec_max_replicas{namespace="$namespace", horizontalpodautoscaler="keda-hpa-$ScaledObject"}` |
| **Active Triggers** | `sum(keda_scaler_active{scaledObject="$ScaledObject", exported_namespace="$namespace"}) or vector(0)` (labelled "External Triggers Active" to make the limitation explicit) |
| **Paused** | `keda_scaled_object_paused{scaledObject="$ScaledObject", exported_namespace="$namespace"}` with value mapping: 1=⏸ Paused (red), 0=▶ Active (green) |

### Row 2 — Replica History

Four series on one time-series panel:

```promql
kube_horizontalpodautoscaler_status_current_replicas{namespace="$namespace", horizontalpodautoscaler="keda-hpa-$ScaledObject"}     # legend: current
kube_horizontalpodautoscaler_status_desired_replicas{namespace="$namespace", horizontalpodautoscaler="keda-hpa-$ScaledObject"}     # legend: desired
kube_horizontalpodautoscaler_spec_min_replicas{namespace="$namespace", horizontalpodautoscaler="keda-hpa-$ScaledObject"}           # legend: min
kube_horizontalpodautoscaler_spec_max_replicas{namespace="$namespace", horizontalpodautoscaler="keda-hpa-$ScaledObject"}           # legend: max
```

Visual: solid filled lines for `current` and `desired`, dashed lines for `min` and `max` (the bounds).

### Row 3a — Metric Value vs Threshold

```promql
# Current measured value (works for cpu/memory AND external)
kube_horizontalpodautoscaler_status_target_metric{namespace="$namespace", horizontalpodautoscaler="keda-hpa-$ScaledObject"}
# legend: {{metric_name}} actual

# Threshold
kube_horizontalpodautoscaler_spec_target_metric{namespace="$namespace", horizontalpodautoscaler="keda-hpa-$ScaledObject"}
# legend: {{metric_name}} threshold
```

For multi-trigger SOs the panel shows multiple actual/threshold pairs. Legend uses `metric_name` (still has `s<N>-` prefix for external — kept as-is for legend clarity).

### Row 3b — Trigger Detail Table

```promql
kube_horizontalpodautoscaler_spec_target_metric{namespace="$namespace", horizontalpodautoscaler="keda-hpa-$ScaledObject"}
```

Instant, table format. After transformations:

| Column | Source |
|---|---|
| Trigger Name | `metric_name` with `s\d+-` prefix stripped where applicable |
| Target Type | `metric_target_type` |
| Threshold | row value |
| Current Value | join `kube_horizontalpodautoscaler_status_target_metric` by `metric_name` |
| Active | join `keda_scaler_active` by `metric_name` (empty cell for cpu/memory) |
| Last Error | join `keda_scaler_errors_total` 1h delta by `scaler` (empty for cpu/memory) |

### Row 4 — Scaler Errors / Latency / Active (external only — populated for external scalers, "No data" otherwise)

```promql
# Panel A — error rate
sum by (scaler) (rate(keda_scaler_errors_total{scaledObject="$ScaledObject", exported_namespace="$namespace"}[5m]))

# Panel B — p95 metric fetch latency
histogram_quantile(0.95,
  sum by (scaler, le) (
    rate(keda_scaler_metrics_latency_seconds_bucket{scaledObject="$ScaledObject", exported_namespace="$namespace"}[5m])
  )
)

# Panel C — active state over time
keda_scaler_active{scaledObject="$ScaledObject", exported_namespace="$namespace"}
```

### Header link block

- **← Back to Inventory** → `/d/keda-workload-inventory/keda-workload-inventory?var-Namespace=$namespace`
- **Deep CPU View** → `/d/keda-workload-cpu/keda-workload-cpu?var-Namespace=$namespace` (always present; only useful if the SO has cpu/memory triggers; user clicks judiciously)

---

## CPU template rename + adjust

Mechanical work; no query rewrites because the existing dashboard already uses `$namespace` template variable.

```bash
git mv lab/grafana/dashboards/keda-demo-cpu-scaling.json \
       lab/grafana/dashboards/keda-workload-cpu.json
```

JSON edits inside the file:

- `"uid": "keda-demo-cpu-scaling"` → `"uid": "keda-workload-cpu"`
- `"title": "KEDA Demo - CPU Autoscaling"` → `"title": "KEDA Workload — CPU Deep View"`
- Default value of `Namespace` template variable: `demo-cpu` → `All` (so it isn't demo-coupled by default)
- Description text replaced: "Deep CPU view for any ScaledObject using cpu/memory triggers. Adds per-pod cAdvisor CPU detail and zone-spread visualization on top of the generic Workload Detail signals."
- Header link block added: "← Back to Inventory" and "← Back to Detail".

---

## Doc updates

Lands AFTER PR #10 (user guide) merges. This work depends on PR #10's `docs/keda-monitoring-user-guide.md` existing.

### `docs/keda-monitoring-user-guide.md` — §2 rewrite

Replace the existing three-dashboard subsections with one table + one paragraph:

```markdown
## The Grafana dashboards for you

Five dashboards live in the **KEDA Lab** Grafana folder. The first two are
your day-to-day tools; the others answer specific questions.

| Dashboard | UID | When to use |
|---|---|---|
| KEDA Workload Inventory   | keda-workload-inventory | **Start here.** Find your ScaledObject, click into Detail. Works for all 7 trigger types (cpu, memory, prometheus, nats-jetstream, redis, cron, metrics-api). |
| KEDA Workload Detail      | keda-workload-detail    | One ScaledObject's full picture: replicas, trigger value vs threshold, error/latency for external scalers. |
| KEDA Workload — CPU Deep  | keda-workload-cpu       | Extra detail for cpu/memory triggers: per-pod cAdvisor CPU, zone spread. |
| KEDA Operations           | keda-operations         | Platform-team's KEDA health view. Use to confirm "is KEDA itself healthy?" before opening a ticket. |
| KEDA Deprecations         | keda-deprecations       | Track 2.18 upgrade blockers in your namespace. |

You don't need to clone or customize any of these. Inventory and Detail are
scaler-agnostic and built from per-HPA metrics that work uniformly for every
trigger type.
```

Drop the obsolete "Duplicate this dashboard and customize" paragraph entirely.

### `docs/lab-overview.md` — §5 Dashboards section

Update the dashboard listing to reflect the new 6 dashboards (workload-inventory, workload-detail, workload-cpu, operations, platform-slo, monitoring-stack — plus the remotely-fetched keda-deprecations from the KDW chart). Bump the "Last updated" date to the current date.

---

## Failure modes / known limitations

| Scenario | Mitigation |
|---|---|
| `kube_horizontalpodautoscaler_*` not scraped (kube-state-metrics down) | Inventory + Detail show "No data". Platform's `KedaOperatorDown`-style alerts catch the upstream issue separately. |
| Multi-trigger SO with mixed cpu + prometheus triggers | Inventory shows two rows for that SO (one per trigger); Detail's "Trigger Detail Table" shows two rows. Acceptable; matches the underlying reality. |
| ScaledJob (not ScaledObject) | Out of scope. ScaledJobs don't create HPAs, so they don't appear in `kube_horizontalpodautoscaler_*`. A separate future dashboard handles ScaledJob inventory; not in this spec. |
| `keda_scaler_active` series doesn't appear for cpu/memory | Documented as expected. "Active Triggers" stat is labelled "External Triggers Active" to make the limitation explicit. Row 4 of Detail shows "No data" for cpu/memory-only SOs. |
| User has SOs in a namespace they aren't authorized to see | Out of scope. The lab uses a single Prometheus / Grafana; multi-tenancy isolation is not addressed by this spec. |
| `keda_scaled_object_paused` series is `null` (the SO was never paused) | Stat panel falls back via `or vector(0)`. |
| Workload uses a scaler not on the 7-type list (e.g. azure-* — out-of-scope per non-goals) | Inventory's "Trigger Type Distribution" displays it under whatever name `s<N>-X` maps to. Detail panels render correctly because all underlying queries are agnostic to trigger type. |

---

## Testing strategy

Five-layer verification. All on the live lab unless otherwise noted.

### Level 1 — JSON parse + dashboards load

```bash
for f in lab/grafana/dashboards/keda-workload-*.json; do
  python3 -m json.tool "$f" > /dev/null || { echo "BAD JSON: $f"; exit 1; }
  uid=$(jq -r '.uid' "$f")
  expected=$(basename "$f" .json)
  [[ "$uid" == "$expected" ]] || { echo "UID MISMATCH: $f has $uid, expected $expected"; exit 1; }
done

make install-grafana
sleep 5
make grafana &
sleep 3
for uid in keda-workload-inventory keda-workload-detail keda-workload-cpu; do
  title=$(curl -s -u admin:admin "http://localhost:3000/api/dashboards/uid/$uid" | jq -r '.dashboard.title // "MISSING"')
  echo "$uid → $title"
done
```

Expected output: three non-MISSING titles.

### Level 2 — Panels render with data

Manual UI walkthrough on the lab cluster after `make recreate` (so all 3 lab workloads are running: demo-cpu, demo-prom, legacy-cpu).

**Inventory dashboard**, Namespace=All:
- Total ScaledObjects stat ≥ 3
- Main table shows ≥ 3 rows, with at least `cpu` and `prometheus` visible in Trigger Type column
- Pie chart shows ≥ 2 segments
- Click SO row → opens Detail dashboard with `var-Namespace` and `var-ScaledObject` pre-filled

**Detail dashboard**, ScaledObject=`prom-demo`:
- All 6 stat panels populated
- Replica History time series has data for last 1h
- Metric Value vs Threshold shows 2 lines
- Trigger Detail table has 1 row
- Row 4 (Scaler Errors / Latency / Active) renders non-empty (external scaler)

**Detail dashboard**, ScaledObject=`cpu-demo`:
- Row 1–3 populated
- Row 4 shows "No data" — that's correct (cpu trigger, no KEDA adapter involvement)
- Active Triggers stat reads 0

**Workload CPU dashboard** (renamed), Namespace=demo-cpu:
- All panels behave identically to the pre-rename keda-demo-cpu-scaling. (Regression check.)

### Level 3 — Coverage spot-check for 7 scaler types

Lab only exercises 2 of the 7 trigger types in production use. A throwaway verification script (`lab/scripts/dashboards-coverage-test.sh`, **not** part of `make up`) creates stub ScaledObjects for the missing 5 (memory uses real cAdvisor; prometheus, nats-jetstream, redis, cron, metrics-api all register against fake-or-self external sources).

```bash
./lab/scripts/dashboards-coverage-test.sh apply
# Wait 60s for HPAs to register and Prometheus to scrape.
# Then verify Inventory dashboard's main table contains all 7 trigger types via:
curl -s http://localhost:9090/api/v1/query?query='count by (metric_name) (kube_horizontalpodautoscaler_spec_target_metric{horizontalpodautoscaler=~"keda-hpa-.*"})' | jq '.data.result[] | .metric.metric_name'
# Expected output includes: cpu, memory, s0-prometheus, s0-nats-jetstream, s0-redis, s0-cron, s0-metrics-api
./lab/scripts/dashboards-coverage-test.sh delete
```

### Level 4 — Cross-dashboard data link

From a fresh Inventory page, click the ScaledObject column on a row → must arrive at Detail with `var-Namespace=demo-prom&var-ScaledObject=prom-demo` (or equivalent) visible in the URL. Verify manually for at least:
- a cpu-trigger SO (verify the CPU Deep link is reachable and useful)
- a prometheus-trigger SO (verify Row 4 of Detail populates)

### Level 5 — Doc verification

After PR #10 merges and this PR rebases:
- §2 of `docs/keda-monitoring-user-guide.md` references all 5 dashboard UIDs correctly (grep-verify against actual JSON UIDs)
- `docs/lab-overview.md` "Last updated" matches the merge date

---

## Implementation footprint

| Path | Change |
|---|---|
| `lab/grafana/dashboards/keda-workload-inventory.json` | NEW (built in UI, exported) |
| `lab/grafana/dashboards/keda-workload-detail.json` | NEW (built in UI, exported) |
| `lab/grafana/dashboards/keda-workload-cpu.json` | RENAMED from `keda-demo-cpu-scaling.json` (`git mv`) + minor JSON edits (uid, title, default namespace value, header link block) — the old path no longer exists |
| `lab/scripts/dashboards-coverage-test.sh` | NEW (throwaway verification helper, not wired to `make up`) |
| `docs/keda-monitoring-user-guide.md` | §2 rewrite (small; depends on PR #10 having merged first) |
| `docs/lab-overview.md` | §5 update (small) |

No changes to:
- `lab/prometheus/values.yaml`
- `lab/scripts/install-grafana.sh` (its `--from-file=lab/grafana/dashboards` already picks up new files)
- KEDA Helm values or any other chart
- `Makefile`, `up.sh`, or any other lifecycle script

---

## Out of scope / future work

- **ScaledJob dashboards** — ScaledJobs don't create HPAs and so don't appear in `kube_horizontalpodautoscaler_*` metrics. A separate dashboard built on `keda_resource_*` and Job/Pod metrics would handle them. Future spec.
- **Multi-tenancy / RBAC** — Grafana Org/Folder permissions to restrict tenants to their own namespaces. Out of scope; the lab is single-tenant.
- **Tenant-onboarded source-of-truth dashboards** — for Prometheus-trigger users, helping them link to their own metric-source dashboards. Could be done via a Grafana panel link, but requires per-workload config.
- **Custom-resource-state-metrics** to expose `ScaledObject` CRD fields directly (e.g. trigger definitions, paused state) — would simplify the inventory data model. Significant install + maintenance footprint; deferred.
- **Workload-team-side alerting** to fire when *their* SO has been at max for X minutes, with `audience: workload-owner` routing — separate concern, depends on Alertmanager routing tree (separate spec from the 2026-05-12 alert-tier audit).
