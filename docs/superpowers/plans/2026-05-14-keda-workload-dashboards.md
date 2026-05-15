# keda-workload-dashboards Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

> **Revision (2026-05-15, during PR #11 review):** Task 1 (rename `keda-demo-cpu-scaling.json` → `keda-workload-cpu.json`) was **reverted**. The CPU Deep View dashboard was deleted outright — the new Workload Detail covers every trigger type uniformly, and a third overlapping dashboard wasn't worth the maintenance. The plan text below for Task 1 is historical; in the final repo there is no `keda-workload-cpu.json`. Tasks 2–8 still apply (with header-link references to the CPU dashboard removed during the same revision).

**Goal:** Add two scaler-agnostic Grafana dashboards (Workload Inventory + Workload Detail), so workload teams can find any ScaledObject and drill into its scaling behaviour without per-scaler-type custom dashboards.

**Architecture:** Three dashboard JSON files under `lab/grafana/dashboards/` (provisioned via the existing `grafana-dashboards` ConfigMap by `lab/scripts/install-grafana.sh`). Each task edits JSON in place, runs `make install-grafana`, and verifies via Grafana's HTTP API. Coverage verification uses a throwaway shell script that creates stub ScaledObjects for all 7 production trigger types and confirms they show up in the inventory.

**Tech Stack:** Grafana 11 dashboard JSON; `kube_horizontalpodautoscaler_*` from kube-state-metrics; `keda_scaler_*` and `keda_scaled_object_paused` from KEDA operator; `make install-grafana` + curl against `localhost:3000` for verification.

**Spec:** `docs/superpowers/specs/2026-05-14-keda-workload-dashboards-design.md` (commit `0241439`).

---

## Implementation strategy notes

- **No Grafana UI builds.** The spec recommends authoring in UI then exporting; that workflow assumes a human. This plan instead uses an existing dashboard (`lab/grafana/dashboards/keda-operations.json` for inventory-style table panels, `keda-demo-cpu-scaling.json` for replica-history time series patterns) as a structural template and adapts queries/panels. Lower risk than hand-writing JSON from scratch.
- **JSON authoring discipline.** Always start a new dashboard by copying an existing one as a base, then edit fields, never write JSON from scratch. Keep the same `schemaVersion`, `tags`, `editable`, `annotations`, `time`, `timepicker` blocks. Replace `id`/`uid`/`title`, then rewrite panels.
- **Pre-flight:** confirm the lab cluster is up (`make status`) before any task that uses `make install-grafana` or curls Grafana. All tasks except T1 (pure file edits) assume `kind-keda-lab` is running with the Prometheus + Grafana stack deployed.

---

## File structure

| Path | Edit type | Responsibility |
|---|---|---|
| `lab/grafana/dashboards/keda-workload-cpu.json` | RENAMED from `keda-demo-cpu-scaling.json` | Deep CPU view (renamed; queries unchanged) |
| `lab/grafana/dashboards/keda-workload-inventory.json` | NEW | Cross-namespace ScaledObject inventory + trigger distribution |
| `lab/grafana/dashboards/keda-workload-detail.json` | NEW | Per-SO drilldown (replicas, metric value vs threshold, scaler health) |
| `lab/scripts/dashboards-coverage-test.sh` | NEW (executable) | Apply/delete stub SOs for the 5 missing trigger types; verify inventory shows all 7 |
| `docs/keda-monitoring-user-guide.md` | MODIFY §2 (gated on PR #10 merging first) | Replace "duplicate and customize" guidance with the 5-dashboard table |
| `docs/lab-overview.md` | MODIFY §5 (small) | Update dashboard list to include the 3 new/renamed dashboards |

Working directory throughout: `/Users/wys1203/go/src/github.com/wys1203/keda-labs`. Branch: `workload-dashboards` (already created off `main`, currently holds the spec commit `0241439`).

---

## Reference: expected end-state dashboard UIDs

After Task 1–3 complete, `lab/grafana/dashboards/` should contain these JSON files (4 lab-core dashboards; `keda-deprecations.json` is fetched at install time from the remote KDW repo and not in tree):

```
keda-operations.json            (untouched)
keda-platform-slo.json          (untouched)
keda-workload-cpu.json          (renamed from keda-demo-cpu-scaling.json)
keda-workload-detail.json       (NEW)
keda-workload-inventory.json    (NEW)
monitoring-stack.json           (untouched)
```

`keda-demo-cpu-scaling.json` MUST NOT exist after Task 1.

---

## Tasks

### Task 1: Rename CPU dashboard + adjust metadata

**Files:**
- Modify (rename): `lab/grafana/dashboards/keda-demo-cpu-scaling.json` → `lab/grafana/dashboards/keda-workload-cpu.json`

No query changes — the existing dashboard already uses `$namespace` template variable. Only header metadata changes.

- [ ] **Step 1: Pre-flight — confirm baseline**

```bash
ls lab/grafana/dashboards/keda-demo-cpu-scaling.json
jq -r '.uid, .title' lab/grafana/dashboards/keda-demo-cpu-scaling.json
```

Expected: file exists. `uid` = `keda-demo-cpu-scaling`. `title` = something like `KEDA Demo - CPU Autoscaling`.

- [ ] **Step 2: Git-rename the file**

```bash
git mv lab/grafana/dashboards/keda-demo-cpu-scaling.json \
       lab/grafana/dashboards/keda-workload-cpu.json
```

- [ ] **Step 3: Update the JSON header fields**

Using `jq` (preserves all other fields exactly):

```bash
jq '
  .uid   = "keda-workload-cpu" |
  .title = "KEDA Workload — CPU Deep View" |
  .description = "Deep CPU view for any ScaledObject using cpu/memory triggers. Adds per-pod cAdvisor CPU detail and zone-spread visualization on top of the generic Workload Detail signals."
' lab/grafana/dashboards/keda-workload-cpu.json > /tmp/cpu.json && \
  mv /tmp/cpu.json lab/grafana/dashboards/keda-workload-cpu.json
```

- [ ] **Step 4: Change default value of `Namespace` template variable**

Find the templating var named `Namespace` (or whichever is the namespace multi-select) and change its `current` block to default to `All`. Use this jq invocation:

```bash
jq '
  .templating.list |= map(
    if .name == "namespace" or .name == "Namespace"
    then .current = {"selected": true, "text": "All", "value": "$__all"}
    else .
    end
  )
' lab/grafana/dashboards/keda-workload-cpu.json > /tmp/cpu.json && \
  mv /tmp/cpu.json lab/grafana/dashboards/keda-workload-cpu.json
```

If the variable name in the JSON is different (e.g., capitalized), adjust the predicate; verify which name was used:

```bash
jq -r '.templating.list[] | .name' lab/grafana/dashboards/keda-workload-cpu.json
```

- [ ] **Step 5: Add a header dashboard-link block pointing back to Inventory + Detail**

Find the top-level `links` array (if absent, the field is just `[]`). Replace with:

```bash
jq '
  .links = [
    {"asDropdown": false, "icon": "external link", "includeVars": true, "keepTime": true,
     "tags": [], "targetBlank": false, "title": "← Back to Workload Inventory",
     "tooltip": "", "type": "link", "url": "/d/keda-workload-inventory/keda-workload-inventory"},
    {"asDropdown": false, "icon": "external link", "includeVars": true, "keepTime": true,
     "tags": [], "targetBlank": false, "title": "← Back to Workload Detail",
     "tooltip": "", "type": "link", "url": "/d/keda-workload-detail/keda-workload-detail"}
  ]
' lab/grafana/dashboards/keda-workload-cpu.json > /tmp/cpu.json && \
  mv /tmp/cpu.json lab/grafana/dashboards/keda-workload-cpu.json
```

`includeVars: true` carries the `$namespace` (and `$prodsuite`) variables across the link so the destination dashboard preserves the user's filter.

- [ ] **Step 6: JSON syntax + UID match check**

```bash
python3 -m json.tool lab/grafana/dashboards/keda-workload-cpu.json > /dev/null
uid=$(jq -r '.uid' lab/grafana/dashboards/keda-workload-cpu.json)
[[ "$uid" == "keda-workload-cpu" ]] || { echo "UID MISMATCH: $uid"; exit 1; }
jq -r '.title' lab/grafana/dashboards/keda-workload-cpu.json
```

Expected: JSON valid, UID = `keda-workload-cpu`, title = `KEDA Workload — CPU Deep View`.

- [ ] **Step 7: Apply to live Grafana**

```bash
make install-grafana
```

Wait for the rollout to finish.

- [ ] **Step 8: Verify dashboard accessible via API**

```bash
kubectl --context kind-keda-lab -n monitoring port-forward svc/grafana 3000:80 >/dev/null 2>&1 &
PF=$!; sleep 3
curl -s -u admin:admin "http://localhost:3000/api/dashboards/uid/keda-workload-cpu" | jq -r '.dashboard.title'
echo "===old UID should now be 404==="
curl -s -u admin:admin -o /dev/null -w "%{http_code}\n" "http://localhost:3000/api/dashboards/uid/keda-demo-cpu-scaling"
kill $PF 2>/dev/null
```

Expected: title `KEDA Workload — CPU Deep View`; old UID returns `404`.

- [ ] **Step 9: Commit**

```bash
git add lab/grafana/dashboards/keda-workload-cpu.json
git commit -m "feat(grafana): rename keda-demo-cpu-scaling -> keda-workload-cpu (deep CPU template)"
```

---

### Task 2: Build Workload Inventory dashboard

**Files:**
- Create: `lab/grafana/dashboards/keda-workload-inventory.json`

Big task. Implementer should authors the JSON by copying `keda-operations.json` as a structural base (because it has the multi-query table-panel pattern we need) then replacing panels.

- [ ] **Step 1: Copy keda-operations.json as a starting structure**

```bash
cp lab/grafana/dashboards/keda-operations.json lab/grafana/dashboards/keda-workload-inventory.json
```

- [ ] **Step 2: Reset header metadata**

```bash
jq '
  .uid   = "keda-workload-inventory" |
  .title = "KEDA Workload Inventory" |
  .description = "Cross-namespace ScaledObject inventory. Find any ScaledObject across the cluster by namespace and trigger type. Click a row to drill into KEDA Workload Detail." |
  .tags  = ["keda", "workloads"] |
  .links = [
    {"asDropdown": false, "icon": "external link", "includeVars": true, "keepTime": true,
     "tags": [], "targetBlank": false, "title": "KEDA Workload Detail →",
     "tooltip": "", "type": "link", "url": "/d/keda-workload-detail/keda-workload-detail"}
  ] |
  .panels = []
' lab/grafana/dashboards/keda-workload-inventory.json > /tmp/inv.json && \
  mv /tmp/inv.json lab/grafana/dashboards/keda-workload-inventory.json
```

After this step, the templating block (Datasource/Prodsuite/Namespace), `time`, `timepicker`, etc. are inherited from keda-operations. Panels list is empty — Task 2 fills it.

- [ ] **Step 3: Set Namespace default to `All`**

```bash
jq '
  .templating.list |= map(
    if .name == "namespace" or .name == "Namespace"
    then .current = {"selected": true, "text": "All", "value": "$__all"}
    else .
    end
  )
' lab/grafana/dashboards/keda-workload-inventory.json > /tmp/inv.json && \
  mv /tmp/inv.json lab/grafana/dashboards/keda-workload-inventory.json
```

- [ ] **Step 4: Add Row 1 — 4 stat panels**

The Grafana panel JSON for stat panels is large. Build with this jq script that appends 4 panels:

```bash
NAMESPACE_VAR="namespace"   # adjust if Step 2 verification showed different casing
DS_VAR="datasource"

jq --arg ns "$NAMESPACE_VAR" --arg ds "$DS_VAR" '
  .panels += [
    {
      "id": 100, "type": "stat", "title": "Total ScaledObjects",
      "gridPos": {"h":4,"w":6,"x":0,"y":0},
      "datasource": {"type":"prometheus","uid":"${"+$ds+"}"},
      "targets": [{"refId":"A","expr":"count(kube_horizontalpodautoscaler_info{horizontalpodautoscaler=~\"keda-hpa-.*\", namespace=~\"$"+$ns+"\"})"}],
      "fieldConfig": {"defaults":{"color":{"mode":"thresholds"},"thresholds":{"mode":"absolute","steps":[{"color":"blue","value":null}]}}}
    },
    {
      "id": 101, "type": "stat", "title": "Pinned at Max",
      "gridPos": {"h":4,"w":6,"x":6,"y":0},
      "datasource": {"type":"prometheus","uid":"${"+$ds+"}"},
      "targets": [{"refId":"A","expr":"count((kube_horizontalpodautoscaler_status_current_replicas{horizontalpodautoscaler=~\"keda-hpa-.*\", namespace=~\"$"+$ns+"\"} == on(namespace, horizontalpodautoscaler) kube_horizontalpodautoscaler_spec_max_replicas{horizontalpodautoscaler=~\"keda-hpa-.*\", namespace=~\"$"+$ns+"\"}) > 0) or vector(0)"}],
      "fieldConfig": {"defaults":{"color":{"mode":"thresholds"},"thresholds":{"mode":"absolute","steps":[{"color":"green","value":null},{"color":"orange","value":1}]}}}
    },
    {
      "id": 102, "type": "stat", "title": "Paused",
      "gridPos": {"h":4,"w":6,"x":12,"y":0},
      "datasource": {"type":"prometheus","uid":"${"+$ds+"}"},
      "targets": [{"refId":"A","expr":"count(keda_scaled_object_paused{exported_namespace=~\"$"+$ns+"\"} == 1) or vector(0)"}],
      "fieldConfig": {"defaults":{"color":{"mode":"thresholds"},"thresholds":{"mode":"absolute","steps":[{"color":"green","value":null},{"color":"orange","value":1}]}}}
    },
    {
      "id": 103, "type": "stat", "title": "With Errors (1h)",
      "gridPos": {"h":4,"w":6,"x":18,"y":0},
      "datasource": {"type":"prometheus","uid":"${"+$ds+"}"},
      "targets": [{"refId":"A","expr":"count(increase(keda_scaled_object_errors_total{exported_namespace=~\"$"+$ns+"\"}[1h]) > 0) or vector(0)"}],
      "fieldConfig": {"defaults":{"color":{"mode":"thresholds"},"thresholds":{"mode":"absolute","steps":[{"color":"green","value":null},{"color":"red","value":1}]}}}
    }
  ]
' lab/grafana/dashboards/keda-workload-inventory.json > /tmp/inv.json && \
  mv /tmp/inv.json lab/grafana/dashboards/keda-workload-inventory.json
```

- [ ] **Step 5: Add Row 2 — Main Inventory Table**

The table needs 4 parallel queries with table-format + merge transformations.

```bash
NAMESPACE_VAR="namespace"
DS_VAR="datasource"

jq --arg ns "$NAMESPACE_VAR" --arg ds "$DS_VAR" '
  .panels += [
    {
      "id": 110, "type": "table", "title": "ScaledObject Inventory",
      "gridPos": {"h":10,"w":24,"x":0,"y":4},
      "datasource": {"type":"prometheus","uid":"${"+$ds+"}"},
      "targets": [
        {"refId":"A","format":"table","instant":true,
         "expr":"kube_horizontalpodautoscaler_spec_target_metric{horizontalpodautoscaler=~\"keda-hpa-.*\", namespace=~\"$"+$ns+"\"}"},
        {"refId":"B","format":"table","instant":true,
         "expr":"kube_horizontalpodautoscaler_info{horizontalpodautoscaler=~\"keda-hpa-.*\", namespace=~\"$"+$ns+"\"}"},
        {"refId":"C","format":"table","instant":true,
         "expr":"kube_horizontalpodautoscaler_spec_min_replicas{horizontalpodautoscaler=~\"keda-hpa-.*\", namespace=~\"$"+$ns+"\"}"},
        {"refId":"D","format":"table","instant":true,
         "expr":"kube_horizontalpodautoscaler_status_current_replicas{horizontalpodautoscaler=~\"keda-hpa-.*\", namespace=~\"$"+$ns+"\"}"},
        {"refId":"E","format":"table","instant":true,
         "expr":"kube_horizontalpodautoscaler_status_desired_replicas{horizontalpodautoscaler=~\"keda-hpa-.*\", namespace=~\"$"+$ns+"\"}"},
        {"refId":"F","format":"table","instant":true,
         "expr":"kube_horizontalpodautoscaler_spec_max_replicas{horizontalpodautoscaler=~\"keda-hpa-.*\", namespace=~\"$"+$ns+"\"}"},
        {"refId":"G","format":"table","instant":true,
         "expr":"keda_scaled_object_paused{exported_namespace=~\"$"+$ns+"\"}"},
        {"refId":"H","format":"table","instant":true,
         "expr":"increase(keda_scaled_object_errors_total{exported_namespace=~\"$"+$ns+"\"}[1h])"}
      ],
      "transformations": [
        {"id":"merge","options":{}},
        {"id":"renameByRegex","options":{"regex":"Value #A","renamePattern":"Threshold"}},
        {"id":"renameByRegex","options":{"regex":"Value #D","renamePattern":"Current"}},
        {"id":"renameByRegex","options":{"regex":"Value #E","renamePattern":"Desired"}},
        {"id":"renameByRegex","options":{"regex":"Value #C","renamePattern":"Min"}},
        {"id":"renameByRegex","options":{"regex":"Value #F","renamePattern":"Max"}},
        {"id":"renameByRegex","options":{"regex":"Value #G","renamePattern":"Paused"}},
        {"id":"renameByRegex","options":{"regex":"Value #H","renamePattern":"Errors 1h"}},
        {"id":"organize","options":{
            "excludeByName": {"Time":true,"Value #B":true,"__name__":true,"app":true,"app_kubernetes_io_component":true,"app_kubernetes_io_instance":true,"app_kubernetes_io_managed_by":true,"app_kubernetes_io_name":true,"app_kubernetes_io_part_of":true,"app_kubernetes_io_version":true,"helm_sh_chart":true,"instance":true,"job":true,"service":true,"node":true,"container":true,"scaletargetref_api_version":true},
            "indexByName": {"namespace":0,"horizontalpodautoscaler":1,"scaletargetref_kind":2,"scaletargetref_name":3,"metric_name":4,"metric_target_type":5,"Threshold":6,"Min":7,"Current":8,"Desired":9,"Max":10,"Paused":11,"Errors 1h":12},
            "renameByName": {"horizontalpodautoscaler":"ScaledObject","scaletargetref_kind":"Target Kind","scaletargetref_name":"Target Name","metric_name":"Trigger","metric_target_type":"Target Type"}
        }}
      ],
      "fieldConfig": {
        "defaults": {"custom": {"align":"auto","displayMode":"auto"}},
        "overrides": [
          {"matcher":{"id":"byName","options":"ScaledObject"},
           "properties":[
             {"id":"mappings","value":[{"type":"regex","options":{"pattern":"^keda-hpa-(.+)$","result":{"text":"$1"}}}]},
             {"id":"links","value":[{"title":"Open Workload Detail","url":"/d/keda-workload-detail/keda-workload-detail?var-namespace=${__data.fields.namespace}&var-scaledobject=${__value.text}"}]}
           ]}
        ]
      }
    }
  ]
' lab/grafana/dashboards/keda-workload-inventory.json > /tmp/inv.json && \
  mv /tmp/inv.json lab/grafana/dashboards/keda-workload-inventory.json
```

Note: the regex mapping on the `ScaledObject` column strips the `keda-hpa-` prefix from the displayed text; the data link uses `${__value.text}` which gets the post-mapping value (i.e. the bare SO name). If Grafana's variable name in the destination dashboard is `Namespace` rather than `namespace`, adjust the link URL.

- [ ] **Step 6: Add Row 3 — Trigger Type Distribution (pie) + Active External Scalers Timeline**

```bash
NAMESPACE_VAR="namespace"
DS_VAR="datasource"

jq --arg ns "$NAMESPACE_VAR" --arg ds "$DS_VAR" '
  .panels += [
    {
      "id": 120, "type": "piechart", "title": "Trigger Type Distribution",
      "gridPos": {"h":6,"w":12,"x":0,"y":14},
      "datasource": {"type":"prometheus","uid":"${"+$ds+"}"},
      "targets": [{"refId":"A","expr":"count by (trigger_type) (label_replace(kube_horizontalpodautoscaler_spec_target_metric{horizontalpodautoscaler=~\"keda-hpa-.*\", namespace=~\"$"+$ns+"\"}, \"trigger_type\", \"$1\", \"metric_name\", \"^s\\\\d+-(.+)$\") or label_replace(kube_horizontalpodautoscaler_spec_target_metric{horizontalpodautoscaler=~\"keda-hpa-.*\", namespace=~\"$"+$ns+"\", metric_name=~\"cpu|memory\"}, \"trigger_type\", \"$1\", \"metric_name\", \"(cpu|memory)\"))","legendFormat":"{{trigger_type}}"}],
      "options": {"legend":{"displayMode":"list","placement":"right"}}
    },
    {
      "id": 121, "type": "timeseries", "title": "Active External Scalers (cpu/memory not represented)",
      "gridPos": {"h":6,"w":12,"x":12,"y":14},
      "datasource": {"type":"prometheus","uid":"${"+$ds+"}"},
      "targets": [{"refId":"A","expr":"sum by (scaler) (keda_scaler_active{exported_namespace=~\"$"+$ns+"\"})","legendFormat":"{{scaler}}"}]
    }
  ]
' lab/grafana/dashboards/keda-workload-inventory.json > /tmp/inv.json && \
  mv /tmp/inv.json lab/grafana/dashboards/keda-workload-inventory.json
```

- [ ] **Step 7: Add Row 4 — Recent Errors Table**

```bash
NAMESPACE_VAR="namespace"
DS_VAR="datasource"

jq --arg ns "$NAMESPACE_VAR" --arg ds "$DS_VAR" '
  .panels += [
    {
      "id": 130, "type": "table", "title": "Recent Errors (last 1h)",
      "gridPos": {"h":6,"w":24,"x":0,"y":20},
      "datasource": {"type":"prometheus","uid":"${"+$ds+"}"},
      "targets": [{"refId":"A","format":"table","instant":true,
        "expr":"topk(20, increase(keda_scaled_object_errors_total{exported_namespace=~\"$"+$ns+"\"}[1h])) > 0"}],
      "transformations": [
        {"id":"organize","options":{
            "excludeByName": {"Time":true,"__name__":true,"app_kubernetes_io_component":true,"app_kubernetes_io_instance":true,"app_kubernetes_io_managed_by":true,"app_kubernetes_io_name":true,"app_kubernetes_io_part_of":true,"app_kubernetes_io_version":true,"helm_sh_chart":true,"instance":true,"job":true,"service":true,"node":true},
            "indexByName": {"exported_namespace":0,"scaledObject":1,"Value":2},
            "renameByName": {"exported_namespace":"Namespace","scaledObject":"ScaledObject","Value":"Errors (1h)"}
        }}
      ]
    }
  ]
' lab/grafana/dashboards/keda-workload-inventory.json > /tmp/inv.json && \
  mv /tmp/inv.json lab/grafana/dashboards/keda-workload-inventory.json
```

- [ ] **Step 8: JSON syntax + structural sanity check**

```bash
python3 -m json.tool lab/grafana/dashboards/keda-workload-inventory.json > /dev/null
jq '.uid, .title, (.panels | length)' lab/grafana/dashboards/keda-workload-inventory.json
```

Expected: 3 lines: `"keda-workload-inventory"`, `"KEDA Workload Inventory"`, `7` (4 stats + 1 main table + 2 row-3 panels + 1 row-4 errors table = 8... actually let me recount: 4 stats in row 1, 1 table in row 2, 2 panels in row 3, 1 table in row 4 = 8 panels). Expected panel count = **8**.

- [ ] **Step 9: Apply + verify dashboard loads**

```bash
make install-grafana
sleep 3
kubectl --context kind-keda-lab -n monitoring port-forward svc/grafana 3000:80 >/dev/null 2>&1 &
PF=$!; sleep 3
curl -s -u admin:admin "http://localhost:3000/api/dashboards/uid/keda-workload-inventory" | jq -r '.dashboard.title, (.dashboard.panels | length)'
kill $PF 2>/dev/null
```

Expected: `KEDA Workload Inventory`, `8`.

- [ ] **Step 10: Visual smoke test (manual)**

```bash
make grafana &
```

Open `http://localhost:3000/d/keda-workload-inventory/keda-workload-inventory` and confirm:
- All 8 panels render
- "Total ScaledObjects" stat shows a number ≥ 3 (lab has demo-cpu, demo-prom, legacy-cpu)
- Main table has ≥ 3 rows, with `cpu` and `s0-prometheus` visible in the Trigger column
- Pie chart has ≥ 2 segments
- (Data link click is tested in Task 4 after Detail dashboard exists.)

If any panel shows "No data" unexpectedly, do not commit — debug PromQL using the Prometheus port-forward.

- [ ] **Step 11: Commit**

```bash
git add lab/grafana/dashboards/keda-workload-inventory.json
git commit -m "feat(grafana): add keda-workload-inventory dashboard (scaler-agnostic SO catalog)"
```

---

### Task 3: Build Workload Detail dashboard

**Files:**
- Create: `lab/grafana/dashboards/keda-workload-detail.json`

Similar approach to Task 2: copy `keda-operations.json` as base, replace metadata + panels.

- [ ] **Step 1: Copy + reset metadata**

```bash
cp lab/grafana/dashboards/keda-operations.json lab/grafana/dashboards/keda-workload-detail.json

jq '
  .uid   = "keda-workload-detail" |
  .title = "KEDA Workload Detail" |
  .description = "Per-ScaledObject drilldown: replicas, trigger value vs threshold, scaler errors/latency for external scalers. Pick a Namespace and ScaledObject from the template variables." |
  .tags  = ["keda", "workloads"] |
  .links = [
    {"asDropdown": false, "icon": "external link", "includeVars": true, "keepTime": true,
     "tags": [], "targetBlank": false, "title": "← KEDA Workload Inventory",
     "tooltip": "", "type": "link", "url": "/d/keda-workload-inventory/keda-workload-inventory"},
    {"asDropdown": false, "icon": "external link", "includeVars": true, "keepTime": true,
     "tags": [], "targetBlank": false, "title": "Deep CPU View →",
     "tooltip": "(useful when this SO uses cpu/memory triggers)", "type": "link", "url": "/d/keda-workload-cpu/keda-workload-cpu"}
  ] |
  .panels = []
' lab/grafana/dashboards/keda-workload-detail.json > /tmp/det.json && \
  mv /tmp/det.json lab/grafana/dashboards/keda-workload-detail.json
```

- [ ] **Step 2: Add `ScaledObject` template variable**

The Detail dashboard needs one more template variable beyond Datasource/Prodsuite/Namespace. Append to the templating list:

```bash
NAMESPACE_VAR="namespace"
DS_VAR="datasource"

jq --arg ns "$NAMESPACE_VAR" --arg ds "$DS_VAR" '
  .templating.list += [
    {
      "name": "scaledobject",
      "type": "query",
      "label": "ScaledObject",
      "datasource": {"type":"prometheus","uid":"${"+$ds+"}"},
      "query": "label_values(kube_horizontalpodautoscaler_info{horizontalpodautoscaler=~\"keda-hpa-.*\", namespace=~\"$"+$ns+"\"}, horizontalpodautoscaler)",
      "regex": "/keda-hpa-(.+)/",
      "multi": false,
      "includeAll": false,
      "refresh": 2,
      "sort": 1,
      "current": {"selected": false, "text": "", "value": ""}
    }
  ]
' lab/grafana/dashboards/keda-workload-detail.json > /tmp/det.json && \
  mv /tmp/det.json lab/grafana/dashboards/keda-workload-detail.json
```

The `regex` extracts the SO name from the HPA name (strips `keda-hpa-` prefix). The variable value (used in panel queries) is the bare SO name.

- [ ] **Step 3: Set Namespace default to single-value (not All)**

For the Detail dashboard, the `Namespace` should be single-select (since `ScaledObject` is single-select and depends on a specific namespace). Edit:

```bash
jq '
  .templating.list |= map(
    if .name == "namespace" or .name == "Namespace"
    then .multi = false | .includeAll = false | .current = {"selected": false, "text": "", "value": ""}
    else .
    end
  )
' lab/grafana/dashboards/keda-workload-detail.json > /tmp/det.json && \
  mv /tmp/det.json lab/grafana/dashboards/keda-workload-detail.json
```

- [ ] **Step 4: Add Row 1 — 6 stat panels**

```bash
NAMESPACE_VAR="namespace"
SO_VAR="scaledobject"
DS_VAR="datasource"

jq --arg ns "$NAMESPACE_VAR" --arg so "$SO_VAR" --arg ds "$DS_VAR" '
  .panels += [
    {"id": 200, "type": "stat", "title": "Current Replicas",
     "gridPos": {"h":3,"w":4,"x":0,"y":0},
     "datasource": {"type":"prometheus","uid":"${"+$ds+"}"},
     "targets": [{"refId":"A","expr":"kube_horizontalpodautoscaler_status_current_replicas{namespace=\"$"+$ns+"\", horizontalpodautoscaler=\"keda-hpa-$"+$so+"\"}"}]
    },
    {"id": 201, "type": "stat", "title": "Desired",
     "gridPos": {"h":3,"w":4,"x":4,"y":0},
     "datasource": {"type":"prometheus","uid":"${"+$ds+"}"},
     "targets": [{"refId":"A","expr":"kube_horizontalpodautoscaler_status_desired_replicas{namespace=\"$"+$ns+"\", horizontalpodautoscaler=\"keda-hpa-$"+$so+"\"}"}]
    },
    {"id": 202, "type": "stat", "title": "Min",
     "gridPos": {"h":3,"w":4,"x":8,"y":0},
     "datasource": {"type":"prometheus","uid":"${"+$ds+"}"},
     "targets": [{"refId":"A","expr":"kube_horizontalpodautoscaler_spec_min_replicas{namespace=\"$"+$ns+"\", horizontalpodautoscaler=\"keda-hpa-$"+$so+"\"}"}]
    },
    {"id": 203, "type": "stat", "title": "Max",
     "gridPos": {"h":3,"w":4,"x":12,"y":0},
     "datasource": {"type":"prometheus","uid":"${"+$ds+"}"},
     "targets": [{"refId":"A","expr":"kube_horizontalpodautoscaler_spec_max_replicas{namespace=\"$"+$ns+"\", horizontalpodautoscaler=\"keda-hpa-$"+$so+"\"}"}]
    },
    {"id": 204, "type": "stat", "title": "External Triggers Active",
     "gridPos": {"h":3,"w":4,"x":16,"y":0},
     "datasource": {"type":"prometheus","uid":"${"+$ds+"}"},
     "targets": [{"refId":"A","expr":"sum(keda_scaler_active{scaledObject=\"$"+$so+"\", exported_namespace=\"$"+$ns+"\"}) or vector(0)"}]
    },
    {"id": 205, "type": "stat", "title": "Paused",
     "gridPos": {"h":3,"w":4,"x":20,"y":0},
     "datasource": {"type":"prometheus","uid":"${"+$ds+"}"},
     "targets": [{"refId":"A","expr":"keda_scaled_object_paused{scaledObject=\"$"+$so+"\", exported_namespace=\"$"+$ns+"\"}"}],
     "fieldConfig": {"defaults": {"mappings": [{"type":"value","options":{"0":{"text":"▶ Active","color":"green"},"1":{"text":"⏸ Paused","color":"red"}}}]}}
    }
  ]
' lab/grafana/dashboards/keda-workload-detail.json > /tmp/det.json && \
  mv /tmp/det.json lab/grafana/dashboards/keda-workload-detail.json
```

- [ ] **Step 5: Add Row 2 — Replica History time series**

```bash
NAMESPACE_VAR="namespace"
SO_VAR="scaledobject"
DS_VAR="datasource"

jq --arg ns "$NAMESPACE_VAR" --arg so "$SO_VAR" --arg ds "$DS_VAR" '
  .panels += [
    {
      "id": 210, "type": "timeseries", "title": "Replicas over time",
      "gridPos": {"h":9,"w":24,"x":0,"y":3},
      "datasource": {"type":"prometheus","uid":"${"+$ds+"}"},
      "targets": [
        {"refId":"A","legendFormat":"current","expr":"kube_horizontalpodautoscaler_status_current_replicas{namespace=\"$"+$ns+"\", horizontalpodautoscaler=\"keda-hpa-$"+$so+"\"}"},
        {"refId":"B","legendFormat":"desired","expr":"kube_horizontalpodautoscaler_status_desired_replicas{namespace=\"$"+$ns+"\", horizontalpodautoscaler=\"keda-hpa-$"+$so+"\"}"},
        {"refId":"C","legendFormat":"min","expr":"kube_horizontalpodautoscaler_spec_min_replicas{namespace=\"$"+$ns+"\", horizontalpodautoscaler=\"keda-hpa-$"+$so+"\"}"},
        {"refId":"D","legendFormat":"max","expr":"kube_horizontalpodautoscaler_spec_max_replicas{namespace=\"$"+$ns+"\", horizontalpodautoscaler=\"keda-hpa-$"+$so+"\"}"}
      ],
      "fieldConfig": {"overrides": [
        {"matcher":{"id":"byName","options":"min"},"properties":[{"id":"custom.lineStyle","value":{"dash":[6,4],"fill":"dash"}}]},
        {"matcher":{"id":"byName","options":"max"},"properties":[{"id":"custom.lineStyle","value":{"dash":[6,4],"fill":"dash"}}]}
      ]}
    }
  ]
' lab/grafana/dashboards/keda-workload-detail.json > /tmp/det.json && \
  mv /tmp/det.json lab/grafana/dashboards/keda-workload-detail.json
```

- [ ] **Step 6: Add Row 3 — Metric Value vs Threshold + Trigger Detail Table**

```bash
NAMESPACE_VAR="namespace"
SO_VAR="scaledobject"
DS_VAR="datasource"

jq --arg ns "$NAMESPACE_VAR" --arg so "$SO_VAR" --arg ds "$DS_VAR" '
  .panels += [
    {
      "id": 220, "type": "timeseries", "title": "Metric Value vs Threshold",
      "gridPos": {"h":8,"w":12,"x":0,"y":12},
      "datasource": {"type":"prometheus","uid":"${"+$ds+"}"},
      "targets": [
        {"refId":"A","legendFormat":"{{metric_name}} actual",
         "expr":"kube_horizontalpodautoscaler_status_target_metric{namespace=\"$"+$ns+"\", horizontalpodautoscaler=\"keda-hpa-$"+$so+"\"}"},
        {"refId":"B","legendFormat":"{{metric_name}} threshold",
         "expr":"kube_horizontalpodautoscaler_spec_target_metric{namespace=\"$"+$ns+"\", horizontalpodautoscaler=\"keda-hpa-$"+$so+"\"}"}
      ]
    },
    {
      "id": 221, "type": "table", "title": "Triggers",
      "gridPos": {"h":8,"w":12,"x":12,"y":12},
      "datasource": {"type":"prometheus","uid":"${"+$ds+"}"},
      "targets": [
        {"refId":"A","format":"table","instant":true,
         "expr":"kube_horizontalpodautoscaler_spec_target_metric{namespace=\"$"+$ns+"\", horizontalpodautoscaler=\"keda-hpa-$"+$so+"\"}"},
        {"refId":"B","format":"table","instant":true,
         "expr":"kube_horizontalpodautoscaler_status_target_metric{namespace=\"$"+$ns+"\", horizontalpodautoscaler=\"keda-hpa-$"+$so+"\"}"}
      ],
      "transformations": [
        {"id":"merge","options":{}},
        {"id":"renameByRegex","options":{"regex":"Value #A","renamePattern":"Threshold"}},
        {"id":"renameByRegex","options":{"regex":"Value #B","renamePattern":"Current"}},
        {"id":"organize","options":{
            "excludeByName": {"Time":true,"__name__":true,"app_kubernetes_io_component":true,"app_kubernetes_io_instance":true,"app_kubernetes_io_managed_by":true,"app_kubernetes_io_name":true,"app_kubernetes_io_part_of":true,"app_kubernetes_io_version":true,"helm_sh_chart":true,"instance":true,"job":true,"service":true,"node":true,"namespace":true,"horizontalpodautoscaler":true},
            "indexByName": {"metric_name":0,"metric_target_type":1,"Threshold":2,"Current":3},
            "renameByName": {"metric_name":"Trigger","metric_target_type":"Type"}
        }}
      ]
    }
  ]
' lab/grafana/dashboards/keda-workload-detail.json > /tmp/det.json && \
  mv /tmp/det.json lab/grafana/dashboards/keda-workload-detail.json
```

- [ ] **Step 7: Add Row 4 — Scaler health (external scalers only)**

```bash
NAMESPACE_VAR="namespace"
SO_VAR="scaledobject"
DS_VAR="datasource"

jq --arg ns "$NAMESPACE_VAR" --arg so "$SO_VAR" --arg ds "$DS_VAR" '
  .panels += [
    {
      "id": 230, "type": "timeseries", "title": "Scaler Errors (external only)",
      "gridPos": {"h":6,"w":8,"x":0,"y":20},
      "datasource": {"type":"prometheus","uid":"${"+$ds+"}"},
      "targets": [{"refId":"A","legendFormat":"{{scaler}}",
        "expr":"sum by (scaler) (rate(keda_scaler_errors_total{scaledObject=\"$"+$so+"\", exported_namespace=\"$"+$ns+"\"}[5m]))"}]
    },
    {
      "id": 231, "type": "timeseries", "title": "Fetch Latency p95 (external only)",
      "gridPos": {"h":6,"w":8,"x":8,"y":20},
      "datasource": {"type":"prometheus","uid":"${"+$ds+"}"},
      "targets": [{"refId":"A","legendFormat":"{{scaler}}",
        "expr":"histogram_quantile(0.95, sum by (scaler, le) (rate(keda_scaler_metrics_latency_seconds_bucket{scaledObject=\"$"+$so+"\", exported_namespace=\"$"+$ns+"\"}[5m])))"}]
    },
    {
      "id": 232, "type": "timeseries", "title": "Active State (external only)",
      "gridPos": {"h":6,"w":8,"x":16,"y":20},
      "datasource": {"type":"prometheus","uid":"${"+$ds+"}"},
      "targets": [{"refId":"A","legendFormat":"{{scaler}}",
        "expr":"keda_scaler_active{scaledObject=\"$"+$so+"\", exported_namespace=\"$"+$ns+"\"}"}]
    }
  ]
' lab/grafana/dashboards/keda-workload-detail.json > /tmp/det.json && \
  mv /tmp/det.json lab/grafana/dashboards/keda-workload-detail.json
```

- [ ] **Step 8: JSON syntax + structural sanity**

```bash
python3 -m json.tool lab/grafana/dashboards/keda-workload-detail.json > /dev/null
jq '.uid, .title, (.panels | length), (.templating.list | map(.name) | sort)' lab/grafana/dashboards/keda-workload-detail.json
```

Expected: `"keda-workload-detail"`, `"KEDA Workload Detail"`, `12` panels (6 stats + 1 replica history + 2 row-3 + 3 row-4 = 12), template variables include `["datasource","namespace","prodsuite","scaledobject"]` (alphabetized).

- [ ] **Step 9: Apply + verify**

```bash
make install-grafana
sleep 3
kubectl --context kind-keda-lab -n monitoring port-forward svc/grafana 3000:80 >/dev/null 2>&1 &
PF=$!; sleep 3
curl -s -u admin:admin "http://localhost:3000/api/dashboards/uid/keda-workload-detail" | jq -r '.dashboard.title, (.dashboard.panels | length)'
kill $PF 2>/dev/null
```

Expected: `KEDA Workload Detail`, `12`.

- [ ] **Step 10: Visual smoke test (manual, two SOs)**

```bash
make grafana &
```

Open the Detail dashboard:
1. Set `Namespace=demo-prom`, `ScaledObject=prom-demo`. Row 1 stats populate; Row 2 replica history non-empty; Row 4 scaler health non-empty.
2. Set `Namespace=demo-cpu`, `ScaledObject=cpu-demo`. Row 1–3 populate; Row 4 reads "No data" (expected for cpu trigger).

- [ ] **Step 11: Commit**

```bash
git add lab/grafana/dashboards/keda-workload-detail.json
git commit -m "feat(grafana): add keda-workload-detail dashboard (per-SO drilldown)"
```

---

### Task 4: Cross-dashboard navigation smoke test

No file edits — verifies the data links wired in Tasks 1–3.

- [ ] **Step 1: Port-forward Grafana**

```bash
make grafana &
sleep 3
```

- [ ] **Step 2: Inventory → Detail click-through**

Open `http://localhost:3000/d/keda-workload-inventory`. Set Namespace=All. Click the `ScaledObject` cell of a row showing `prom-demo`. URL must arrive at:

```
/d/keda-workload-detail/keda-workload-detail?var-namespace=demo-prom&var-scaledobject=prom-demo
```

Confirm dashboard renders with that SO selected.

- [ ] **Step 3: Detail → CPU Deep link**

From the Detail dashboard (any SO), click the header "Deep CPU View →" link. Should land on `/d/keda-workload-cpu` with the namespace variable carried over (via `includeVars`).

- [ ] **Step 4: CPU → Inventory back link**

From CPU Deep dashboard, click "← Back to Workload Inventory". Should land on Inventory with namespace carried over.

- [ ] **Step 5: No commit** — this task is observation only.

If any link fails (broken URL, missing variable), open the relevant dashboard JSON, fix the `links` array or the column override URL template, re-run `make install-grafana`, retest. Once all four navigations pass, mark complete.

---

### Task 5: Coverage test script

**Files:**
- Create: `lab/scripts/dashboards-coverage-test.sh` (executable, NOT wired to `make up`)

The lab exercises 2 of 7 production trigger types (cpu, prometheus). This script creates stub SOs for the missing 5 in a throwaway namespace `dashboards-coverage`, verifies all 7 trigger types appear in the Inventory's main query, then deletes everything.

- [ ] **Step 1: Create the script**

```bash
cat > lab/scripts/dashboards-coverage-test.sh <<'SCRIPT'
#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "${SCRIPT_DIR}/../../scripts/lib.sh"

ensure_cluster
require_cmd kubectl

NS="dashboards-coverage"
MODE="${1:-apply}"

EXPECTED_METRIC_NAMES=(
  "cpu"
  "memory"
  "s0-prometheus"
  "s0-nats-jetstream"
  "s0-redis"
  "s0-cron"
  "s0-metrics-api"
)

usage() {
  echo "Usage: $0 {apply|verify|delete}"
  echo "  apply  — create stub ScaledObjects in namespace $NS"
  echo "  verify — query Prometheus, confirm all 7 trigger types appear"
  echo "  delete — remove the namespace and all stubs"
  exit 2
}

case "$MODE" in
  apply)
    log "creating namespace $NS"
    kubectl create namespace "$NS" --dry-run=client -o yaml | kubectl apply -f -

    # Deploy a pause pod that we can target with the SOs
    cat <<YAML | kubectl apply -f -
apiVersion: apps/v1
kind: Deployment
metadata: {name: target, namespace: $NS}
spec:
  replicas: 1
  selector: {matchLabels: {app: target}}
  template:
    metadata: {labels: {app: target}}
    spec:
      containers:
        - name: pause
          image: registry.k8s.io/pause:3.9
          resources:
            requests: {cpu: 50m, memory: 32Mi}
            limits:   {cpu: 200m, memory: 64Mi}
YAML

    # 5 SOs, one per missing trigger type. All target the same Deployment.
    # External-scaler URLs/sources are fake; KEDA still registers the SO
    # and kube-state-metrics still emits HPA spec metrics for it, even
    # though the scaler will report errors. That's enough for inventory.
    for name in memory promstub natsstub redisstub cronstub metricsapistub; do
      kubectl -n "$NS" delete scaledobject "$name" --ignore-not-found
    done

    cat <<YAML | kubectl apply -f -
---
apiVersion: keda.sh/v1alpha1
kind: ScaledObject
metadata: {name: memory, namespace: $NS}
spec:
  scaleTargetRef: {name: target}
  minReplicaCount: 1
  maxReplicaCount: 3
  triggers:
    - type: memory
      metricType: Utilization
      metadata: {value: "80"}
---
apiVersion: keda.sh/v1alpha1
kind: ScaledObject
metadata: {name: promstub, namespace: $NS}
spec:
  scaleTargetRef: {name: target}
  minReplicaCount: 1
  maxReplicaCount: 3
  triggers:
    - type: prometheus
      metadata:
        serverAddress: http://prometheus-server.monitoring.svc:80
        metricName: stub
        threshold: "1"
        query: vector(0)
---
apiVersion: keda.sh/v1alpha1
kind: ScaledObject
metadata: {name: natsstub, namespace: $NS}
spec:
  scaleTargetRef: {name: target}
  minReplicaCount: 1
  maxReplicaCount: 3
  triggers:
    - type: nats-jetstream
      metadata:
        natsServerMonitoringEndpoint: "nats.example:8222"
        account: "$G"
        stream: stub
        consumer: stub
        lagThreshold: "10"
---
apiVersion: keda.sh/v1alpha1
kind: ScaledObject
metadata: {name: redisstub, namespace: $NS}
spec:
  scaleTargetRef: {name: target}
  minReplicaCount: 1
  maxReplicaCount: 3
  triggers:
    - type: redis
      metadata:
        address: redis.example:6379
        listName: stub
        listLength: "5"
---
apiVersion: keda.sh/v1alpha1
kind: ScaledObject
metadata: {name: cronstub, namespace: $NS}
spec:
  scaleTargetRef: {name: target}
  minReplicaCount: 0
  maxReplicaCount: 3
  triggers:
    - type: cron
      metadata:
        timezone: UTC
        start: "0 9 * * 1-5"
        end: "0 17 * * 1-5"
        desiredReplicas: "2"
---
apiVersion: keda.sh/v1alpha1
kind: ScaledObject
metadata: {name: metricsapistub, namespace: $NS}
spec:
  scaleTargetRef: {name: target}
  minReplicaCount: 1
  maxReplicaCount: 3
  triggers:
    - type: metrics-api
      metadata:
        targetValue: "5"
        url: http://example.invalid/metric
        valueLocation: 'value'
YAML
    log "stubs applied in $NS — wait 60s for kube-state-metrics to scrape, then run: $0 verify"
    ;;

  verify)
    require_cmd curl
    require_cmd jq

    kubectl -n monitoring port-forward svc/prometheus-server 9090:80 >/dev/null 2>&1 &
    PF=$!
    sleep 3

    log "querying kube_horizontalpodautoscaler_spec_target_metric for namespace=$NS"
    actual="$(curl -s "http://localhost:9090/api/v1/query?query=count%20by%20(metric_name)%20(kube_horizontalpodautoscaler_spec_target_metric%7Bhorizontalpodautoscaler%3D~%22keda-hpa-.%2A%22%2Cnamespace%3D%22${NS}%22%7D)" \
      | jq -r '.data.result[] | .metric.metric_name' | sort)"

    kill $PF 2>/dev/null

    echo "Observed metric_name values in $NS:"
    echo "$actual" | sed 's/^/  /'

    missing=()
    for expected in "${EXPECTED_METRIC_NAMES[@]}"; do
      # cpu and memory triggers don't exist in this script — those types
      # are validated in the main lab (demo-cpu and the memory stub above).
      if ! echo "$actual" | grep -qx "$expected"; then
        missing+=("$expected")
      fi
    done

    if [[ ${#missing[@]} -gt 0 ]]; then
      log "MISSING trigger types in inventory:"
      printf '  %s\n' "${missing[@]}"
      exit 1
    fi
    log "all 7 trigger types present in Inventory dashboard's source query"
    ;;

  delete)
    log "deleting namespace $NS and all stubs"
    kubectl delete namespace "$NS" --ignore-not-found --wait=false
    ;;

  *)
    usage
    ;;
esac
SCRIPT
chmod +x lab/scripts/dashboards-coverage-test.sh
```

- [ ] **Step 2: Confirm script syntax**

```bash
bash -n lab/scripts/dashboards-coverage-test.sh
./lab/scripts/dashboards-coverage-test.sh 2>&1 | head -3  # should print Usage
```

- [ ] **Step 3: Commit**

```bash
git add lab/scripts/dashboards-coverage-test.sh
git commit -m "feat(lab): dashboards-coverage-test.sh — verify all 7 trigger types appear"
```

---

### Task 6: Run coverage verification end-to-end

No file changes — runs Task 5's script against the live lab.

- [ ] **Step 1: Apply stubs**

```bash
./lab/scripts/dashboards-coverage-test.sh apply
```

- [ ] **Step 2: Wait for kube-state-metrics to scrape (60s)**

```bash
sleep 60
```

- [ ] **Step 3: Verify**

```bash
./lab/scripts/dashboards-coverage-test.sh verify
```

Expected: prints all 7 trigger type names and "all 7 trigger types present in Inventory dashboard's source query".

If something's missing: leave the stubs in place, port-forward Prometheus, query manually for the missing metric_name to find out what kube-state-metrics is reporting (e.g. the SO may have failed to create an HPA at all because the trigger config was rejected).

- [ ] **Step 4: Visual confirmation**

```bash
make grafana &
```

Open `http://localhost:3000/d/keda-workload-inventory`. Set Namespace=dashboards-coverage. Inventory main table should show ≥ 5 rows. Trigger Type Distribution pie should show at least 5 distinct trigger types.

- [ ] **Step 5: Tear down**

```bash
./lab/scripts/dashboards-coverage-test.sh delete
```

- [ ] **Step 6: No commit** — observation only.

---

### Task 7: Doc updates

**Files:**
- Modify: `docs/keda-monitoring-user-guide.md` — §2 rewrite
- Modify: `docs/lab-overview.md` — §5 update

**GATING**: this task assumes PR #10 has merged so `docs/keda-monitoring-user-guide.md` exists on `main`. **Before starting Task 7, run:**

```bash
git fetch origin
git log --oneline origin/main | head -5
ls docs/keda-monitoring-user-guide.md
```

If the file doesn't exist on `origin/main` yet, **pause Task 7 and ask the controller** what to do (options: rebase on the latest main after PR #10 lands, or skip Task 7 entirely and ship the dashboards without doc changes).

Assuming the file exists:

- [ ] **Step 1: Rebase on latest main**

```bash
git fetch origin
git rebase origin/main
```

- [ ] **Step 2: Rewrite §2 of the monitoring user guide**

Find the section that lists the existing dashboards (probably titled "The three Grafana dashboards for you" or similar). Replace with this exact content:

```markdown
## The Grafana dashboards for you

Five dashboards live in the **KEDA Lab** Grafana folder. The first two are
your day-to-day tools; the others answer specific questions.

| Dashboard | UID | When to use |
|---|---|---|
| KEDA Workload Inventory   | `keda-workload-inventory` | **Start here.** Find your ScaledObject, click into Detail. Works for all 7 trigger types (cpu, memory, prometheus, nats-jetstream, redis, cron, metrics-api). |
| KEDA Workload Detail      | `keda-workload-detail`    | One ScaledObject's full picture: replicas, trigger value vs threshold, error/latency for external scalers. |
| KEDA Workload — CPU Deep  | `keda-workload-cpu`       | Extra detail for cpu/memory triggers: per-pod cAdvisor CPU, zone spread. |
| KEDA Operations           | `keda-operations`         | Platform-team's KEDA health view. Use to confirm "is KEDA itself healthy?" before opening a ticket. |
| KEDA Deprecations         | `keda-deprecations`       | Track 2.18 upgrade blockers in your namespace. |

You don't need to clone or customize any of these. Inventory and Detail are
scaler-agnostic and built from per-HPA metrics that work uniformly for every
trigger type.

Access Grafana via `make grafana` and open `http://localhost:3000` (default
credentials `admin` / `admin`). All five dashboards live in the **KEDA Lab**
folder.
```

Drop the obsolete "Duplicate this dashboard and customize" paragraph from anywhere else in the guide if present.

- [ ] **Step 3: Update lab-overview.md §5**

```bash
grep -n "Three dashboards\|Dashboards are provisioned" docs/lab-overview.md
```

Find the paragraph that lists the dashboards. Update to mention the six dashboards now in the catalog: `keda-workload-inventory`, `keda-workload-detail`, `keda-workload-cpu`, `keda-operations`, `keda-platform-slo`, `monitoring-stack` (plus `keda-deprecations` fetched from the remote KDW chart at install time).

Also update the "Last updated" header to today's date:

```bash
sed -i '' "s/Last updated: .*/Last updated: $(date +%Y-%m-%d)/" docs/lab-overview.md
```

- [ ] **Step 4: Verify rendering**

```bash
python3 -c "import sys; open('docs/keda-monitoring-user-guide.md').read()" > /dev/null
python3 -c "import sys; open('docs/lab-overview.md').read()" > /dev/null
```

Confirm both files parse. (No formal markdown lint in this repo — visual check the diff is sufficient.)

- [ ] **Step 5: Commit**

```bash
git add docs/keda-monitoring-user-guide.md docs/lab-overview.md
git commit -m "docs: update monitoring guide + lab-overview for new workload dashboards"
```

---

### Task 8: Full E2E + push

- [ ] **Step 1: Final dashboard catalog check**

```bash
ls lab/grafana/dashboards/
```

Expected exact list:
```
keda-operations.json
keda-platform-slo.json
keda-workload-cpu.json
keda-workload-detail.json
keda-workload-inventory.json
monitoring-stack.json
```

`keda-demo-cpu-scaling.json` MUST NOT exist.

- [ ] **Step 2: Apply once more from a clean state**

```bash
make install-grafana
```

- [ ] **Step 3: Verify all 6 dashboard UIDs load via API**

```bash
kubectl --context kind-keda-lab -n monitoring port-forward svc/grafana 3000:80 >/dev/null 2>&1 &
PF=$!; sleep 3
for uid in keda-operations keda-platform-slo keda-workload-cpu keda-workload-detail keda-workload-inventory monitoring-stack; do
  title=$(curl -s -u admin:admin "http://localhost:3000/api/dashboards/uid/$uid" | jq -r '.dashboard.title // "MISSING"')
  echo "$uid → $title"
done
kill $PF 2>/dev/null
```

Expected: no MISSING.

- [ ] **Step 4: Confirm old UID is gone**

```bash
kubectl --context kind-keda-lab -n monitoring port-forward svc/grafana 3000:80 >/dev/null 2>&1 &
PF=$!; sleep 3
http_code=$(curl -s -u admin:admin -o /dev/null -w "%{http_code}" "http://localhost:3000/api/dashboards/uid/keda-demo-cpu-scaling")
echo "old UID: $http_code (expected 404)"
kill $PF 2>/dev/null
```

- [ ] **Step 5: Push branch**

```bash
git push
```

If this is a force-needed push (rebase happened in Task 7), use `git push --force-with-lease`. Output a PR URL hint at the end.

- [ ] **Step 6: No commit** — push only.

---

## Self-review

### Spec coverage

| Spec requirement | Implemented in |
|---|---|
| `keda-workload-inventory.json` (NEW) | Task 2 |
| `keda-workload-detail.json` (NEW) | Task 3 |
| `keda-workload-cpu.json` (renamed from `keda-demo-cpu-scaling.json`) | Task 1 |
| Inventory panels: 4 stats + main table + 2 distribution + errors table = 8 panels | Task 2 steps 4–7 |
| Detail panels: 6 stats + replica history + 2 row-3 + 3 row-4 = 12 panels | Task 3 steps 4–7 |
| Cross-navigation (data link Inventory→Detail, header links to Inventory/CPU) | Task 1 step 5 + Task 2 step 5 + Task 3 step 1 + Task 4 verification |
| `ScaledObject` template variable on Detail (regex strips `keda-hpa-` prefix) | Task 3 step 2 |
| `or vector(0)` fallback on count-style stats | Task 2 step 4, Task 3 step 4 |
| `label_replace` on Trigger Type distribution | Task 2 step 6 |
| Doc updates after PR #10 lands | Task 7 (gated) |
| 7-trigger-type coverage verification | Tasks 5 + 6 |
| `lab/scripts/install-grafana.sh` unchanged | not touched by any task; provisioning via `--from-file=lab/grafana/dashboards` already picks up new files |

### Placeholder scan

No "TBD", "TODO", "fill in later", "similar to Task N" — every step has concrete commands. The Task 7 gating ("ask the controller") is not a placeholder, it's a real procedural branch documented to handle the merge-order dependency.

### Type / name consistency

- Dashboard UIDs: `keda-workload-inventory`, `keda-workload-detail`, `keda-workload-cpu` — consistent everywhere.
- Template variable names referenced in PromQL: `namespace`, `scaledobject`, `datasource` (lowercase) — `NAMESPACE_VAR="namespace"` and `SO_VAR="scaledobject"` in shell heredocs, `$namespace` / `$scaledobject` in PromQL strings. Consistent.
- Data link URL format: `?var-namespace=...&var-scaledobject=...` — matches the var names.
- Metric names: `kube_horizontalpodautoscaler_*` for HPA queries (use `namespace` label), `keda_scaler_*` / `keda_scaled_object_*` for KEDA queries (use `exported_namespace` label). Consistent throughout.

### Known risks

- **Grafana template variable name casing**: existing dashboards may use `namespace` (lowercase) or `Namespace` (Pascal). All jq edits in Tasks 1–3 use `if .name == "namespace" or .name == "Namespace"` to handle both. If verification (Step 4 of T1, Step 2 of T2) reveals a different name, adjust the shell `NAMESPACE_VAR` variable in subsequent tasks accordingly.
- **PromQL escaping in shell heredocs**: `\\d+` becomes `\d+` after one level of shell escape. Verify in Task 2 step 8 by `jq -r` reading back the expr string and confirming it's `^s\d+-(.+)$` (single backslash).
- **Coverage stubs failing to create HPAs**: external scalers like nats-jetstream may fail KEDA validation if required metadata is incomplete. The stubs above use minimum-viable configs; if KEDA still rejects, the script's `verify` step will surface the missing trigger type and an investigator can iterate on the stub manifest.

---

## Execution Handoff

Plan complete and saved to `docs/superpowers/plans/2026-05-14-keda-workload-dashboards.md`. Two execution options:

**1. Subagent-Driven (recommended)** — I dispatch a fresh subagent per task, review between tasks, fast iteration.

**2. Inline Execution** — Execute tasks in this session using executing-plans, batch execution with checkpoints.

Which approach?
