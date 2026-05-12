# keda-platform-alerts Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Re-tier the lab's KEDA alert rules into a 3-tier audience-aware structure (SLO / component-cause / observation), drop one redundant alert, add two filling platform-coverage gaps, and update the two affected docs.

**Architecture:** Pure Prometheus rule changes in a single file (`lab/prometheus/values.yaml`) plus two documentation refreshes. Each task edits one alert group, re-installs Prometheus via Helm, and verifies the loaded rule set matches the expected sub-state for that group. The final task runs behavioral spot-checks (one per tier) end-to-end.

**Tech Stack:** Prometheus rules YAML; `helm upgrade --install` via `make install-prometheus`; `promtool check rules`; `curl -s :9090/api/v1/rules`; lab kind cluster.

**Spec:** `docs/superpowers/specs/2026-05-12-keda-platform-alerts-design.md` (commit `a46196b`).

---

## Pre-flight: cluster must be up

```bash
make status   # confirms kind-keda-lab is running and KEDA + KDW + monitoring are healthy
```

If not running, `make up` first. Every task in this plan assumes Prometheus is reachable via port-forward.

---

## File structure

| Path | Edit type | Responsibility |
|---|---|---|
| `lab/prometheus/values.yaml` | Modify | All rule edits (single source of truth for Prometheus rules) |
| `docs/lab-overview.md` | Modify (alert table only) | Reflect new tier structure + final per-group counts |
| `docs/keda-deprecation-webhook-zh-TW.md` | Modify (§5.2 alert table) | `KedaDeprecationConfigReloadFailing for: 5m` + `KedaDeprecationErrorViolationsPresent severity: info` |

Working directory throughout: `/Users/wys1203/go/src/github.com/wys1203/keda-labs`. Branch: `alerts-tier-audit` (already created off `main`).

---

## Reference: expected end-state alert names

Used for diff verification in Task 8. Memorize the count (24) and the order (alphabetical):

```
DemoCpuAtMaxReplicas
DemoCpuPodsPending
KedaAdapterToOperatorGrpcErrors
KedaAdapterToOperatorGrpcSilence
KedaAdmissionWebhookLatencyHigh                    ← NEW
KedaAdmissionWebhooksDown
KedaCertNearExpiry
KedaContainerCpuThrottling
KedaContainerMemoryNearLimit                       ← NEW
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
```

`KedaReconcileErrors` MUST NOT appear in this list (dropped).

---

## Tasks

### Task 1: Capture baseline + verify metric availability

**Files:**
- Create: `/tmp/alerts-baseline.txt` (scratch, not committed)

This task is gating: if a metric needed by the two new alerts is missing, downstream tasks must defer those alerts. No file modifications and no commit.

- [ ] **Step 1: Port-forward Prometheus**

```bash
kubectl -n monitoring port-forward svc/prometheus-server 9090:80 &
sleep 3
```

- [ ] **Step 2: Capture baseline loaded alerts**

```bash
curl -s http://localhost:9090/api/v1/rules \
  | jq -r '.data.groups[].rules[] | select(.type=="alerting") | .name' \
  | sort > /tmp/alerts-baseline.txt
wc -l /tmp/alerts-baseline.txt
```

Expected: `23 /tmp/alerts-baseline.txt`.

- [ ] **Step 3: Verify `controller_runtime_webhook_request_duration_seconds` exists (for `KedaAdmissionWebhookLatencyHigh`)**

```bash
curl -s "http://localhost:9090/api/v1/query?query=controller_runtime_webhook_request_duration_seconds_count{app_kubernetes_io_name=\"keda-admission-webhooks\"}" \
  | jq '.data.result | length'
```

Expected: `> 0`. If `0`, **flag in Task 4 to defer `KedaAdmissionWebhookLatencyHigh`** — drop that specific alert from this plan and document in your report. The rest of the plan proceeds unchanged.

- [ ] **Step 4: Verify `container_spec_memory_limit_bytes` exists for platform-keda (for `KedaContainerMemoryNearLimit`)**

```bash
curl -s "http://localhost:9090/api/v1/query?query=container_spec_memory_limit_bytes{namespace=\"platform-keda\"}" \
  | jq '.data.result | length'
```

Expected: `> 0`. If `0`, **flag in Task 4 to defer `KedaContainerMemoryNearLimit`** — same rule as above.

- [ ] **Step 5: Stop port-forward**

```bash
kill %1 2>/dev/null || true
```

- [ ] **Step 6: Record findings**

Report at the end of Task 1: which (if any) of the two new alerts must be deferred. This decision propagates to Task 4 only.

No commit for Task 1 (no repo changes).

---

### Task 2: Tier 1 — `keda-platform-slo` group: add four new labels

**Files:**
- Modify: `lab/prometheus/values.yaml` — the four alerts in the `keda-platform-slo` group (around lines 180, 199, 219, 238 — search for `alert: KedaPlatformReconcileBudgetBurnFast` to locate)

Each of the four alerts currently has labels of the form:

```yaml
            labels:
              severity: critical
              component: keda-platform-slo
              slo: reconcile_success
```

(or similar — `severity`, `component`, `slo` only). Add `tier` and `audience`, and change `component` to a uniform value. After edit, each of the four must have **exactly** these labels:

| Alert | severity | tier | component | audience | slo |
|---|---|---|---|---|---|
| `KedaPlatformReconcileBudgetBurnFast` | `critical` | `"1"` | `keda-operator` | `platform` | `reconcile_success` |
| `KedaPlatformReconcileBudgetBurnSlow` | `warning` | `"1"` | `keda-operator` | `platform` | `reconcile_success` |
| `KedaPlatformOperatorUpBudgetBurnFast` | `critical` | `"1"` | `keda-operator` | `platform` | `operator_up` |
| `KedaPlatformOperatorUpBudgetBurnSlow` | `warning` | `"1"` | `keda-operator` | `platform` | `operator_up` |

Note `tier` is quoted (Prometheus rule labels must be strings; bare `1` would be a YAML int).

- [ ] **Step 1: Open the file and locate the keda-platform-slo group**

Use `grep -n "alert: KedaPlatformReconcileBudgetBurnFast" lab/prometheus/values.yaml` to find the first one. The four alerts are sequential within the same group.

- [ ] **Step 2: Edit each `labels:` block for the four alerts**

For each alert, the `labels:` block should end up like (using `KedaPlatformReconcileBudgetBurnFast` as the template):

```yaml
            labels:
              severity: critical
              tier: "1"
              component: keda-operator
              audience: platform
              slo: reconcile_success
```

Keep `severity` as it currently is for each alert (don't change critical↔warning). Replace `component: keda-platform-slo` (or whatever it currently is) with `component: keda-operator`. Add `tier: "1"` and `audience: platform`. Keep the existing `slo:` label.

- [ ] **Step 3: Run `promtool` against the rendered chart values**

```bash
helm template prometheus prometheus-community/prometheus \
  -f lab/prometheus/values.yaml \
  2>/dev/null \
  | yq eval-all 'select(.kind=="ConfigMap" and .metadata.name=="prometheus-server") | .data["alerting_rules.yml"]' - \
  > /tmp/rules.yaml
promtool check rules /tmp/rules.yaml
```

Expected: `SUCCESSFUL` with `N rules found` (N should still be 23 — no alerts added or removed yet, only labels changed).

- [ ] **Step 4: Apply the change**

```bash
make install-prometheus
```

Wait for Helm to finish (~30s). Expected: no error.

- [ ] **Step 5: Verify the new labels are loaded**

```bash
kubectl -n monitoring port-forward svc/prometheus-server 9090:80 &
sleep 3
curl -s http://localhost:9090/api/v1/rules \
  | jq '.data.groups[] | select(.name=="keda-platform-slo") | .rules[] | select(.type=="alerting") | {name: .name, labels: .labels}'
kill %1 2>/dev/null || true
```

Expected: All 4 alerts show `tier: "1"`, `audience: "platform"`, `component: "keda-operator"`.

- [ ] **Step 6: Commit**

```bash
git add lab/prometheus/values.yaml
git commit -m "feat(alerts): Tier 1 labels for keda-platform-slo group"
```

---

### Task 3: Tier 2 — rebalance `keda-control-plane` and `keda-scalers`

This is the largest task. It does five things in one commit because they must land atomically (alert names can't briefly be in two groups):

1. **Drop** `KedaReconcileErrors` from `keda-control-plane` (redundant with Tier 1 SLO).
2. **Add** `KedaAdmissionWebhookLatencyHigh` to `keda-control-plane` (subject to Task 1's metric-availability gate).
3. **Add** `KedaContainerMemoryNearLimit` to `keda-control-plane` (subject to Task 1's gate).
4. **Move** `KedaOperatorLeaderChurn` and `KedaCertNearExpiry` from `keda-scalers` into `keda-control-plane`.
5. **Add Tier 2 labels** to every alert in the resulting `keda-control-plane` group.

**Files:**
- Modify: `lab/prometheus/values.yaml`

After this task, `keda-control-plane` contains these alerts (alphabetical, 11–13 depending on Task 1 gating):

| Alert | severity | tier | component | audience |
|---|---|---|---|---|
| `KedaAdapterToOperatorGrpcErrors` | warning | `"2"` | `keda-operator` | `platform` |
| `KedaAdapterToOperatorGrpcSilence` | critical | `"2"` | `keda-operator` | `platform` |
| `KedaAdmissionWebhookLatencyHigh` *(if gated in)* | warning | `"2"` | `keda-admission-webhooks` | `platform` |
| `KedaAdmissionWebhooksDown` | warning | `"2"` | `keda-admission-webhooks` | `platform` |
| `KedaCertNearExpiry` (moved in from keda-scalers) | warning | `"2"` | `cert-manager` | `platform` |
| `KedaContainerCpuThrottling` | warning | `"2"` | `keda-operator` | `platform` |
| `KedaContainerMemoryNearLimit` *(if gated in)* | warning | `"2"` | `keda-operator` | `platform` |
| `KedaMetricsApiServerDown` | critical | `"2"` | `keda-metrics-apiserver` | `platform` |
| `KedaOperatorDown` | critical | `"2"` | `keda-operator` | `platform` |
| `KedaOperatorLeaderChurn` (moved in from keda-scalers) | warning | `"2"` | `keda-operator` | `platform` |
| `KedaWorkqueueBacklog` | warning | `"2"` | `keda-operator` | `platform` |

And `keda-scalers` group still exists but has been emptied of those two — it will be renamed and reduced in Task 4.

`KedaReconcileErrors` MUST NOT appear in the file after this task.

- [ ] **Step 1: Remove the `KedaReconcileErrors` block**

Locate `- alert: KedaReconcileErrors` (around line 297 — `grep -n KedaReconcileErrors lab/prometheus/values.yaml`). Delete the entire `- alert: ...` block including its `expr:`, `for:`, `labels:`, and `annotations:`. Stop at the next `- alert:` line. Approximately:

```yaml
          - alert: KedaReconcileErrors
            expr: |
              sum by (controller) (
                ...
              ) > 0.1
            for: 10m
            labels:
              ...
            annotations:
              ...
```

After removal, the next alert (`KedaWorkqueueBacklog` at line ~313) should be the line directly after `KedaContainerCpuThrottling`'s annotations block.

- [ ] **Step 2: Update existing keda-control-plane alerts' labels**

For each of these alerts already in the `keda-control-plane` group — `KedaOperatorDown`, `KedaMetricsApiServerDown`, `KedaAdmissionWebhooksDown`, `KedaWorkqueueBacklog`, `KedaContainerCpuThrottling`, `KedaAdapterToOperatorGrpcErrors`, `KedaAdapterToOperatorGrpcSilence` — set the `labels:` block to:

```yaml
            labels:
              severity: <UNCHANGED>          # keep critical or warning as currently set
              tier: "2"
              component: <SEE TABLE ABOVE>   # keda-operator, keda-metrics-apiserver, or keda-admission-webhooks
              audience: platform
```

Drop any stale labels like `component: keda` (replace with the precise component value from the table).

- [ ] **Step 3: Add the two new alerts at the end of `keda-control-plane`**

Conditional on Task 1: only include each alert if its source metric was present.

Insert these alerts at the bottom of the `keda-control-plane` group (just before `      - name: keda-scalers`):

```yaml
          # platform-keda admission webhook latency. apiserver applies
          # a 10s timeout to admission webhooks; p99 > 1s means callers
          # are starting to feel kubectl apply lag, which the up-only SLO
          # cannot detect.
          - alert: KedaAdmissionWebhookLatencyHigh
            expr: |
              histogram_quantile(0.99,
                sum by (le) (
                  rate(controller_runtime_webhook_request_duration_seconds_bucket{app_kubernetes_io_name="keda-admission-webhooks"}[5m])
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
                The 99th-percentile admission webhook handler latency has
                been above 1 second for 10 minutes. apiserver enforces a
                10-second timeout, so this is the early-warning before
                kubectl apply of ScaledObject/ScaledJob starts failing.
                Check the keda-operator pod for resource pressure, leader
                churn, and downstream metrics-apiserver health.

          # Memory pressure on the KEDA operator container. cAdvisor
          # exposes both the working set and the spec limit; when the
          # ratio crosses 0.9 we have 15 minutes' notice before OOMKill.
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
                Working set has been above 90% of the container's memory
                limit for 15 minutes. OOMKill is imminent and will burn
                the SLO. Investigate for memory leak or raise the limit
                in lab/keda/values.yaml.
```

If a metric was missing in Task 1, **omit that specific alert block** but include the other.

- [ ] **Step 4: Move `KedaOperatorLeaderChurn` and `KedaCertNearExpiry` from `keda-scalers` into `keda-control-plane`**

Locate both alerts in the `keda-scalers` group (around lines 498 and 512 — `grep -n "alert: KedaOperatorLeaderChurn\|alert: KedaCertNearExpiry" lab/prometheus/values.yaml`).

Cut the entire `- alert: KedaOperatorLeaderChurn` block (including expr/for/labels/annotations, ~14 lines) and paste it at the bottom of `keda-control-plane` (after the new `KedaContainerMemoryNearLimit` block if it was included, otherwise after the new `KedaAdmissionWebhookLatencyHigh` block).

Same for `KedaCertNearExpiry`.

Update their `labels:` blocks to:

```yaml
            labels:
              severity: warning
              tier: "2"
              component: keda-operator        # for KedaOperatorLeaderChurn
              audience: platform
```

```yaml
            labels:
              severity: warning
              tier: "2"
              component: cert-manager         # for KedaCertNearExpiry
              audience: platform
```

After move, the `keda-scalers` group contains only `KedaScaledObjectErrors`, `KedaScalerErrors`, `KedaScalerMetricsLatencyHigh`, `KedaScaledObjectAtMaxReplicas` (4 alerts) — Task 4 will rename and re-tier this group.

- [ ] **Step 5: Render and check syntax**

```bash
helm template prometheus prometheus-community/prometheus \
  -f lab/prometheus/values.yaml \
  2>/dev/null \
  | yq eval-all 'select(.kind=="ConfigMap" and .metadata.name=="prometheus-server") | .data["alerting_rules.yml"]' - \
  > /tmp/rules.yaml
promtool check rules /tmp/rules.yaml
```

Expected: `SUCCESSFUL`. Rule count should be `23 - 1 (dropped) + 2 (added, if both gated in) = 24`. If one new alert was deferred, count is 23.

- [ ] **Step 6: Apply and verify the new keda-control-plane group**

```bash
make install-prometheus
sleep 3
kubectl -n monitoring port-forward svc/prometheus-server 9090:80 &
sleep 3
curl -s http://localhost:9090/api/v1/rules \
  | jq '.data.groups[] | select(.name=="keda-control-plane") | .rules[] | select(.type=="alerting") | .name' \
  | sort
kill %1 2>/dev/null || true
```

Expected (assuming both new alerts gated in): 11 alphabetically sorted names matching the table at the top of Task 3.

- [ ] **Step 7: Verify `KedaReconcileErrors` is gone**

```bash
kubectl -n monitoring port-forward svc/prometheus-server 9090:80 &
sleep 3
curl -s http://localhost:9090/api/v1/rules \
  | jq '.data.groups[].rules[] | select(.name=="KedaReconcileErrors")'
kill %1 2>/dev/null || true
```

Expected: empty output (no match).

- [ ] **Step 8: Commit**

```bash
git add lab/prometheus/values.yaml
git commit -m "feat(alerts): rebalance Tier 2 keda-control-plane (drop reconcile-errors, add 2, move leader+cert)"
```

If new alerts were deferred, mention that in the commit body:

```bash
git commit -m "feat(alerts): rebalance Tier 2 keda-control-plane

Drop KedaReconcileErrors (redundant with Tier 1 SLO).
Move KedaOperatorLeaderChurn + KedaCertNearExpiry from keda-scalers.
DEFERRED: <which alert>, metric <name> not available in lab Prometheus."
```

---

### Task 4: Tier 3 workloads — rename `keda-scalers` → `keda-workloads`, demote 4 alerts to info

After Task 3, `keda-scalers` contains 4 alerts (`KedaScaledObjectErrors`, `KedaScalerErrors`, `KedaScalerMetricsLatencyHigh`, `KedaScaledObjectAtMaxReplicas`). This task:

1. Renames the group `keda-scalers` → `keda-workloads`.
2. Demotes all 4 alerts' severity from `warning` to `info`.
3. Updates all 4 alerts' label set to the Tier 3 schema.

**Files:**
- Modify: `lab/prometheus/values.yaml`

Target end-state for each of the 4 alerts:

| Alert | severity | tier | component | audience |
|---|---|---|---|---|
| `KedaScaledObjectErrors` | `info` | `"3"` | `workload` | `workload-owner` |
| `KedaScalerErrors` | `info` | `"3"` | `workload` | `workload-owner` |
| `KedaScalerMetricsLatencyHigh` | `info` | `"3"` | `workload` | `workload-owner` |
| `KedaScaledObjectAtMaxReplicas` | `info` | `"3"` | `workload` | `workload-owner` |

`expr:` and `for:` are unchanged.

- [ ] **Step 1: Rename the group**

Find `      - name: keda-scalers` (around line 426 — adjust for offsets from Task 3 edits). Change to `      - name: keda-workloads`.

Update the surrounding comment block if it mentions `keda-scalers`. For example, if there's a `# keda-scalers — ...` comment, change it to `# keda-workloads — Tier 3 observation-only signals for tenant workloads. Severity: info. Not pageable.`

- [ ] **Step 2: For each of the 4 alerts, replace the `labels:` block**

For each of `KedaScaledObjectErrors`, `KedaScalerErrors`, `KedaScalerMetricsLatencyHigh`, `KedaScaledObjectAtMaxReplicas`:

Change the `labels:` block to exactly:

```yaml
            labels:
              severity: info
              tier: "3"
              component: workload
              audience: workload-owner
```

Drop any stale labels.

- [ ] **Step 3: Render and promtool-check**

```bash
helm template prometheus prometheus-community/prometheus \
  -f lab/prometheus/values.yaml \
  2>/dev/null \
  | yq eval-all 'select(.kind=="ConfigMap" and .metadata.name=="prometheus-server") | .data["alerting_rules.yml"]' - \
  > /tmp/rules.yaml
promtool check rules /tmp/rules.yaml
```

Expected: `SUCCESSFUL`.

- [ ] **Step 4: Apply and verify**

```bash
make install-prometheus
sleep 3
kubectl -n monitoring port-forward svc/prometheus-server 9090:80 &
sleep 3
curl -s http://localhost:9090/api/v1/rules \
  | jq '.data.groups[] | select(.name=="keda-workloads") | .rules[] | select(.type=="alerting") | {name: .name, severity: .labels.severity, tier: .labels.tier}'
kill %1 2>/dev/null || true
```

Expected: 4 rules listed, all with `severity: "info"` and `tier: "3"`.

Also verify the old `keda-scalers` name is gone:

```bash
kubectl -n monitoring port-forward svc/prometheus-server 9090:80 &
sleep 3
curl -s http://localhost:9090/api/v1/rules \
  | jq '.data.groups[] | select(.name=="keda-scalers")'
kill %1 2>/dev/null || true
```

Expected: empty output.

- [ ] **Step 5: Commit**

```bash
git add lab/prometheus/values.yaml
git commit -m "feat(alerts): rename keda-scalers -> keda-workloads, demote 4 alerts to Tier 3 info"
```

---

### Task 5: Lab-demo — rename `demo-cpu-workload` → `lab-demo`, demote both alerts to info + `audience: lab-only`

**Files:**
- Modify: `lab/prometheus/values.yaml`

Target end-state:

| Alert | severity | tier | component | audience |
|---|---|---|---|---|
| `DemoCpuAtMaxReplicas` | `info` | `"3"` | `workload` | `lab-only` |
| `DemoCpuPodsPending` | `info` | `"3"` | `workload` | `lab-only` |

- [ ] **Step 1: Rename the group**

Find `      - name: demo-cpu-workload` (around line 526 — adjust for offsets). Change to `      - name: lab-demo`.

Update the comment to: `# lab-demo — Tier 3 observation alerts for the demo workload. Severity: info, audience: lab-only. These never page and are excluded from any production-style rollout of this ruleset.`

- [ ] **Step 2: Replace each alert's `labels:` block**

For both `DemoCpuAtMaxReplicas` and `DemoCpuPodsPending`:

```yaml
            labels:
              severity: info
              tier: "3"
              component: workload
              audience: lab-only
```

- [ ] **Step 3: Render and check**

```bash
helm template prometheus prometheus-community/prometheus \
  -f lab/prometheus/values.yaml \
  2>/dev/null \
  | yq eval-all 'select(.kind=="ConfigMap" and .metadata.name=="prometheus-server") | .data["alerting_rules.yml"]' - \
  > /tmp/rules.yaml
promtool check rules /tmp/rules.yaml
```

Expected: `SUCCESSFUL`.

- [ ] **Step 4: Apply and verify**

```bash
make install-prometheus
sleep 3
kubectl -n monitoring port-forward svc/prometheus-server 9090:80 &
sleep 3
curl -s http://localhost:9090/api/v1/rules \
  | jq '.data.groups[] | select(.name=="lab-demo") | .rules[] | {name: .name, severity: .labels.severity, audience: .labels.audience}'
kill %1 2>/dev/null || true
```

Expected: 2 rules, both `severity: "info"`, `audience: "lab-only"`.

- [ ] **Step 5: Commit**

```bash
git add lab/prometheus/values.yaml
git commit -m "feat(alerts): rename demo-cpu-workload -> lab-demo, demote to Tier 3 lab-only"
```

---

### Task 6: keda-deprecations group — tune `for:` and label

**Files:**
- Modify: `lab/prometheus/values.yaml`

Three changes to the existing `keda-deprecations` group:

1. `KedaDeprecationWebhookDown` — add Tier 2 labels (no other change).
2. `KedaDeprecationConfigReloadFailing` — add Tier 2 labels, bump `for: 0m` → `for: 5m`.
3. `KedaDeprecationErrorViolationsPresent` — change `severity: warning` → `severity: info`, set as Tier 3 with `audience: workload-owner`.

Target end-state:

| Alert | severity | tier | for | component | audience |
|---|---|---|---|---|---|
| `KedaDeprecationWebhookDown` | `critical` | `"2"` | 5m (unchanged) | `keda-deprecation-webhook` | `platform` |
| `KedaDeprecationConfigReloadFailing` | `warning` | `"2"` | **`5m`** ← was `0m` | `keda-deprecation-webhook` | `platform` |
| `KedaDeprecationErrorViolationsPresent` | **`info`** ← was `warning` | `"3"` | 1h (unchanged) | `workload` | `workload-owner` |

- [ ] **Step 1: Edit `KedaDeprecationWebhookDown`'s labels block**

```yaml
            labels:
              severity: critical
              tier: "2"
              component: keda-deprecation-webhook
              audience: platform
```

- [ ] **Step 2: Edit `KedaDeprecationConfigReloadFailing`'s `for:` and labels**

Change `for: 0m` → `for: 5m`. Replace `labels:` block with:

```yaml
            labels:
              severity: warning
              tier: "2"
              component: keda-deprecation-webhook
              audience: platform
```

- [ ] **Step 3: Edit `KedaDeprecationErrorViolationsPresent`'s labels**

```yaml
            labels:
              severity: info
              tier: "3"
              component: workload
              audience: workload-owner
```

- [ ] **Step 4: Render and check**

```bash
helm template prometheus prometheus-community/prometheus \
  -f lab/prometheus/values.yaml \
  2>/dev/null \
  | yq eval-all 'select(.kind=="ConfigMap" and .metadata.name=="prometheus-server") | .data["alerting_rules.yml"]' - \
  > /tmp/rules.yaml
promtool check rules /tmp/rules.yaml
```

Expected: `SUCCESSFUL`.

- [ ] **Step 5: Apply and verify**

```bash
make install-prometheus
sleep 3
kubectl -n monitoring port-forward svc/prometheus-server 9090:80 &
sleep 3
curl -s http://localhost:9090/api/v1/rules \
  | jq '.data.groups[] | select(.name=="keda-deprecations") | .rules[] | {name: .name, severity: .labels.severity, tier: .labels.tier, for: .duration}'
kill %1 2>/dev/null || true
```

Expected:
- `KedaDeprecationWebhookDown` → `severity: critical, tier: "2", for: 300` (5m in seconds)
- `KedaDeprecationConfigReloadFailing` → `severity: warning, tier: "2", for: 300`
- `KedaDeprecationErrorViolationsPresent` → `severity: info, tier: "3", for: 3600`

- [ ] **Step 6: Commit**

```bash
git add lab/prometheus/values.yaml
git commit -m "feat(alerts): label keda-deprecations group, bump ConfigReloadFailing for: 5m, demote ViolationsPresent to info"
```

---

### Task 7: Update docs (`lab-overview.md` + Chinese manual)

**Files:**
- Modify: `docs/lab-overview.md` (alert section per-group table)
- Modify: `docs/keda-deprecation-webhook-zh-TW.md` (§5.2 alert table)

- [ ] **Step 1: Update `docs/lab-overview.md` alert table**

Locate the section that lists alert groups. Look for:

```bash
grep -nE "keda-platform-slo|keda-control-plane|keda-scalers|demo-cpu-workload|keda-deprecations" docs/lab-overview.md
```

Update the per-group table to reflect the new structure. Replace the existing per-group counts with this content (insert at the relevant section — the exact phrasing depends on what's already there; preserve the document's style):

> The alert ruleset is structured into three tiers — see the design spec at `docs/superpowers/specs/2026-05-12-keda-platform-alerts-design.md` for full rationale.
>
> | Group | Tier | Audience | Alert count |
> |---|---|---|---|
> | `keda-platform-slo` | 1 (SLO burn-rate) | platform | 4 |
> | `keda-control-plane` | 2 (component cause) | platform | 11 *(or 9–10 if metric-availability gating in Task 1 deferred either of the two new alerts)* |
> | `keda-deprecations` | 2 + 3 (mixed) | platform / workload-owner | 3 |
> | `keda-workloads` | 3 (observation) | workload-owner | 4 |
> | `lab-demo` | 3 (observation) | lab-only | 2 |
>
> Every alert carries `severity` (`critical` / `warning` / `info`), `tier` (`"1"` / `"2"` / `"3"`), `component`, and `audience` labels. `severity: info` alerts are dashboard-only and never page.

Also update the `Last updated:` line at the top of the doc to `2026-05-12`.

- [ ] **Step 2: Update `docs/keda-deprecation-webhook-zh-TW.md` §5.2 alert table**

Find the §5.2 table:

```bash
grep -nE "Alert.*\| .*\| Severity|KedaDeprecation" docs/keda-deprecation-webhook-zh-TW.md
```

The current section 5.2 has a table with three KDW alerts. Update the row for `KedaDeprecationConfigReloadFailing` to show `for: 5m` (instead of `0m`), and update `KedaDeprecationErrorViolationsPresent`'s `Severity` column from `warning` to `info`. The table is roughly:

```markdown
| `KedaDeprecationWebhookDown` | `up{...} == 0` 持續 5 分鐘 | critical | webhook 失聯;... |
| `KedaDeprecationConfigReloadFailing` | `increase(...{result="error"}[10m]) > 0` 持續 **5 分鐘** | warning | CM 無法 parse,正在用上一份好 config。... |
| `KedaDeprecationErrorViolationsPresent` | `sum(violations{severity="error"}) > 0` 持續 1 小時 | **info** | 還有 fleet 範圍內的 error 級違規... |
```

(Bold the changed cells in your edit; remove the bold once the doc is final — they're just to help you spot the diff.)

Below the table, add one short paragraph:

> 補充:本 webhook 的 alert 依新的三層分類:`KedaDeprecationWebhookDown` 與 `KedaDeprecationConfigReloadFailing` 是 Tier 2(platform pager),`KedaDeprecationErrorViolationsPresent` 是 Tier 3(`severity: info`,只給 dashboard 看,不進 pager)。詳見 `docs/superpowers/specs/2026-05-12-keda-platform-alerts-design.md`。

- [ ] **Step 3: Commit docs**

```bash
git add docs/lab-overview.md docs/keda-deprecation-webhook-zh-TW.md
git commit -m "docs(alerts): refresh lab-overview + KDW manual for tier-based ruleset"
```

---

### Task 8: Full end-to-end verification

This task validates the entire ruleset against the spec, including behavioral spot-checks. No file modifications, no commits.

- [ ] **Step 1: Full alert-name diff against expected end-state**

```bash
kubectl -n monitoring port-forward svc/prometheus-server 9090:80 &
sleep 3
curl -s http://localhost:9090/api/v1/rules \
  | jq -r '.data.groups[].rules[] | select(.type=="alerting") | .name' \
  | sort > /tmp/alerts-final.txt
wc -l /tmp/alerts-final.txt
```

Expected: `24` (or `23` / `22` if Task 1 deferred one or both new alerts).

Then diff against the canonical list. Save this heredoc as `/tmp/alerts-expected.txt`:

```bash
cat > /tmp/alerts-expected.txt <<'EOF'
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
diff /tmp/alerts-final.txt /tmp/alerts-expected.txt
```

Expected: empty output (no diff). If Task 1 deferred a new alert, remove that line from `/tmp/alerts-expected.txt` before diff'ing.

- [ ] **Step 2: Tier-by-group sanity counts**

```bash
curl -s http://localhost:9090/api/v1/rules \
  | jq -r '.data.groups[] | "\(.name): \(.rules | map(select(.type=="alerting")) | length)"'
```

Expected (with both new alerts gated in):
```
stdout-sink: 0
keda-platform-slo: 4
keda-control-plane: 11
keda-deprecations: 3
keda-workloads: 4
lab-demo: 2
```

Total: 24.

- [ ] **Step 3: Tier 1 behavioral spot-check — operator-down → SLO fires**

```bash
kubectl -n platform-keda scale deploy/keda-operator --replicas=0
echo "Waiting up to 3 minutes for KedaPlatformOperatorUpBudgetBurnFast to fire..."
for i in {1..36}; do
  state=$(curl -s http://localhost:9090/api/v1/alerts \
    | jq -r '.data.alerts[] | select(.labels.alertname=="KedaPlatformOperatorUpBudgetBurnFast") | .state' \
    | head -1)
  if [[ "${state}" == "firing" ]]; then
    echo "Tier 1 fired after ${i} polls."
    break
  fi
  sleep 5
done
```

Expected: `Tier 1 fired after N polls.` (N up to 36). If still inactive after 3 minutes, the alert is broken — investigate before restoring.

Restore:
```bash
kubectl -n platform-keda scale deploy/keda-operator --replicas=2
kubectl -n platform-keda rollout status deploy/keda-operator --timeout=60s
```

Wait an additional 2 minutes and confirm the alert resolved:
```bash
sleep 120
curl -s http://localhost:9090/api/v1/alerts \
  | jq '.data.alerts[] | select(.labels.alertname=="KedaPlatformOperatorUpBudgetBurnFast")'
```

Expected: empty (alert no longer in active list).

- [ ] **Step 4: Tier 2 behavioral spot-check — bad CM → ConfigReloadFailing fires after 5m**

```bash
kubectl -n keda-system patch cm kdw-keda-deprecation-webhook-config \
  --type merge -p '{"data":{"config.yaml":"INVALID :::: yaml\n"}}'
echo "Waiting 5+ minutes (for: 5m) for KedaDeprecationConfigReloadFailing to fire..."
for i in {1..72}; do
  state=$(curl -s http://localhost:9090/api/v1/alerts \
    | jq -r '.data.alerts[] | select(.labels.alertname=="KedaDeprecationConfigReloadFailing") | .state' \
    | head -1)
  if [[ "${state}" == "firing" ]]; then
    echo "Tier 2 fired after ${i} polls."
    break
  fi
  sleep 5
done
```

Expected: `Tier 2 fired after N polls.` (60 ≤ N ≤ 72, given the 5-minute `for:`).

Restore (KDW now lives in its own repo + Helm chart since PR #8; the lab's CM is templated by the chart from `lab/charts/values-kdw-lab.yaml`. The simplest way to restore the original CM is to re-run the lab's install script, which re-templates the chart and re-applies):

```bash
make install-webhook
sleep 30
curl -s http://localhost:9090/api/v1/alerts \
  | jq '.data.alerts[] | select(.labels.alertname=="KedaDeprecationConfigReloadFailing")'
```

Expected: empty (alert resolved after CM restored).

- [ ] **Step 5: Tier 3 verification — info alerts have `severity: info`, never enter alerts API as critical/warning**

```bash
# Verify rule label
curl -s http://localhost:9090/api/v1/rules \
  | jq '.data.groups[].rules[] | select(.name=="KedaScaledObjectErrors") | .labels'
```

Expected: `{"severity":"info","tier":"3","component":"workload","audience":"workload-owner"}`.

```bash
# Verify NO info-severity alerts in the active-alerts list (info alerts may still appear in
# /api/v1/alerts because Prometheus tracks all rules; the key is no critical/warning ones
# from Tier 3). Spot-check: count any Tier 3 alert with severity != info.
curl -s http://localhost:9090/api/v1/rules \
  | jq '.data.groups[].rules[] | select(.labels.tier=="3") | select(.labels.severity != "info") | .name'
```

Expected: empty output (no Tier 3 alert has anything other than `severity: info`).

- [ ] **Step 6: Stop port-forward**

```bash
kill %1 2>/dev/null || true
```

- [ ] **Step 7: Push branch**

```bash
git push
```

No commit in Task 8 — only verification.

---

## Self-review

### Spec coverage

| Spec requirement | Implemented in |
|---|---|
| Label schema (severity, tier, component, audience) on every alert | Tasks 2–6 |
| Tier 1: keep 4 SLO burn-rate alerts unchanged + relabel | Task 2 |
| Tier 2: 11–13 component-cause alerts | Task 3 (rebalance) + Task 6 (KDW group portion) |
| `KedaReconcileErrors` dropped | Task 3, step 1 |
| `KedaAdmissionWebhookLatencyHigh` added (gated) | Task 1 (gate) + Task 3, step 3 |
| `KedaContainerMemoryNearLimit` added (gated) | Task 1 (gate) + Task 3, step 3 |
| `KedaOperatorLeaderChurn` + `KedaCertNearExpiry` move from keda-scalers → keda-control-plane | Task 3, step 4 |
| `keda-scalers` → `keda-workloads` rename | Task 4, step 1 |
| `demo-cpu-workload` → `lab-demo` rename | Task 5, step 1 |
| 7 Tier 3 alerts demoted to `severity: info` | Tasks 4, 5, 6 |
| `KedaDeprecationConfigReloadFailing for: 0m → 5m` | Task 6, step 2 |
| `lab-only` audience for the demo-group alerts | Task 5, step 2 |
| Testing: promtool check, loaded-rules diff, behavioral spot-checks | Tasks 3–6 (per-group), Task 8 (full) |
| Docs updates | Task 7 |

No gaps.

### Placeholder scan

Scanned for "TBD", "TODO", "fill in", "implement later", "Add appropriate", "similar to Task N". None present.

### Type consistency

- `tier` is always a quoted string `"1"` / `"2"` / `"3"` (YAML int would change Prometheus's label representation).
- `component` values are drawn from a fixed enum: `keda-operator`, `keda-metrics-apiserver`, `keda-admission-webhooks`, `keda-deprecation-webhook`, `cert-manager`, `workload`. Consistent across all tasks.
- `audience` values: `platform`, `workload-owner`, `lab-only`. Consistent.
- `severity` values: `critical`, `warning`, `info`. Consistent.

No drift.

### Known structural risks

- **Helm + `helm template` rendering**: the `helm template ... | yq ... | promtool` pipeline assumes the chart packages alerting rules into a ConfigMap named `prometheus-server`. If a future chart upgrade renames it, the syntax check in step 3 of each editing task will silently produce empty output. Mitigation: each task's step 4 (`make install-prometheus`) and step 5 (`curl /api/v1/rules`) catches the failure end-to-end.
- **`make install-prometheus` race**: Helm install + Prometheus reload + ConfigMap projection takes ~10–20s. The `sleep 3` between port-forward and `curl` may be too short on a busy machine. If curl returns stale data, retry the verification step after another 10s sleep.

---

## Execution Handoff

Plan complete and saved to `docs/superpowers/plans/2026-05-12-keda-platform-alerts.md`. Two execution options:

**1. Subagent-Driven (recommended)** — I dispatch a fresh subagent per task, review between tasks, fast iteration.

**2. Inline Execution** — Execute tasks in this session using executing-plans, batch execution with checkpoints.

Which approach?
