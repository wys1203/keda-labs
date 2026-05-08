# keda-deprecation-webhook — Design

**Status:** Draft (spec)
**Date:** 2026-05-05
**Owner:** wys1203

## Context

We need to upgrade KEDA from `2.16.1` to `2.18.3` across our fleet (~100+ Kubernetes clusters running `1.24`). KEDA 2.18 contains a breaking change that will cause running ScaledObjects/ScaledJobs to fail validation:

> **CPU/Memory triggers** can no longer use `triggers[].metadata.type`. The trigger-level `metricType` field (introduced in 2.10, deprecated `metadata.type` since) is now mandatory.

Some workloads in the fleet still use the deprecated form. Upgrading without remediation will cause those ScaledObjects to break (HPA stops scaling) on the new KEDA version.

We need to:

1. **Block** new `ScaledObject` / `ScaledJob` resources that introduce the deprecated spec, before they get into the cluster.
2. **Inventory** the existing offenders via metrics so each platform/owner team can see what they need to fix, and Grafana shows fleet-wide migration progress.
3. **Stay flexible** — different teams have different migration timelines; per-namespace exemption needs to be possible without redeploying the webhook binary, because rolling out new images across 100+ clusters is expensive and slow.

## Constraints

- Kubernetes `1.24` — no `ValidatingAdmissionPolicy` (CEL-based) available; that resource is beta in 1.28 and GA in 1.30.
- Kyverno is not available in the fleet.
- cert-manager **is** available in production. Lab environment will install it as part of `make up`.
- We don't want a mutating webhook — silent fixes hide debt.

## Goals

- Reject `CREATE` of `ScaledObject` / `ScaledJob` containing rule-`error`-severity deprecations, in any namespace not explicitly exempted.
- Reject `UPDATE` only when the update **adds** a new rule-`error` violation that wasn't already present (additive-only mode). Updates to objects that already have a violation but don't make it worse are allowed, with a warning.
- Emit Prometheus metrics covering: every existing violation in the cluster, admission rejections, admission warnings, and config-reload health.
- Allow per-cluster, per-namespace tuning of severity (`error` / `warn` / `off`) via a hot-reloadable ConfigMap.
- Provide a pluggable rule framework so KEDA002, KEDA003 etc. can be added by code in future binary releases without touching the webhook plumbing.
- Ship as part of the keda-labs lab so the design can be validated end-to-end before fleet rollout.

## Non-goals

- Authoring rule logic via DSL/CEL in the ConfigMap. Only built-in (compiled) rules are runnable. Adding new rule logic requires a binary release.
- A standalone Helm chart. Lab uses raw manifests; production chart packaging is a follow-on spec.
- Mutating / auto-fixing offending specs.
- A `KedaDeprecationPolicy` CRD. The CM is sufficient for the foreseeable scope.
- Coverage of KEDA CRDs other than `ScaledObject` and `ScaledJob`. Other KEDA resources do not carry a `triggers[]` array so KEDA001 doesn't apply.

---

## Architecture

One Go binary, deployed as a single Deployment (`keda-deprecation-webhook`, abbrev. **KDW**), exposing two listeners and three logical components that all share one rule engine and one config store.

```
              ┌─────────────────────────────────────────┐
              │       keda-deprecation-webhook          │
              │       (Deployment, 2 replicas)          │
              │                                         │
   :9443 ──── │  ValidatingWebhook handler              │
   (HTTPS)    │    POST /validate-keda-sh-v1alpha1      │
              │       ─┐                                │
              │        ├──→  Rule registry              │
              │       ─┘     (KEDA001, ...future)       │
              │              ↑     ↑                    │
              │              │     │ same lint code     │
              │              │     │                    │
              │              │     │       ┌────────┐   │
              │              │     │       │ Config │   │
              │              │     │       │ store  │ ← │── ConfigMap
              │              │     │       │atomic. │   │   (informer, hot-reload)
              │              │     │       │ Value  │   │
              │              │     │       └────────┘   │
              │              ↓     ↓                    │
   :8080 ──── │  Controller (informer-driven)           │
   (HTTP)     │    watches ScaledObject + ScaledJob     │
              │    on every event → run rules → update  │
              │    keda_deprecation_violations gauge    │
              │                                         │
   :8080 ──── │  /metrics  (Prometheus)                 │
   (HTTP)     │  /healthz  /readyz                      │
              └─────────────────────────────────────────┘
```

### Key decisions

| Decision | Choice | Rationale |
| --- | --- | --- |
| Enforcement mode (UPDATE) | **Additive-only** — reject only if UPDATE adds a new error-severity violation; existing violations on UPDATE pass with a warning | Migration ergonomics: don't block someone bumping `maxReplicaCount` just because they haven't migrated the deprecated field yet. Combined with metrics + warnings, debt stays visible without breaking unrelated work |
| Enforcement mode (CREATE) | Reject if any error-severity violation present | New violations are always avoidable — make `kubectl apply` fail loud |
| `failurePolicy` | `Ignore` | Lint-class webhooks should fail open. Controller path provides eventual visibility for anything that slipped through during outages. Alert `KedaDeprecationWebhookDown` covers the gap |
| Webhook scope | Both `ScaledObject` and `ScaledJob` | Same `Spec.Triggers[]` shape, same deprecation applies. Missing `ScaledJob` would leave a hole at upgrade time |
| Mutating webhook | Not used | Silent auto-fix hides debt. Goal is to make owners see + fix |
| Cert management | cert-manager + `selfSigned` Issuer | Same path lab → prod (consistency). cainjector handles CA bundle injection automatically |
| Configuration source | ConfigMap, hot-reloadable | Operators on 100+ clusters can change severity / overrides without an image release |

### Tech stack

- Go, controller-runtime (KEDA itself uses controller-runtime; we reuse its webhook server, manager, informers).
- KEDA CRD types via `import "github.com/kedacore/keda/v2/apis/keda/v1alpha1"` — no code generation; we don't define new CRDs.
- Single binary, single image, single Deployment.
- **Per-replica responsibility split:**
  - Webhook server, ConfigMap watcher, Namespace watcher: **run on all replicas** (every pod must serve admission with current config + namespace labels).
  - `ScaledObject` / `ScaledJob` reconcilers (gauge emission): **run only on the leader** (`Runnable.NeedLeaderElection() = true` via controller-runtime). Both pods running the gauge would double-count and race on `DeleteLabelValues`.
  - Counters (`*_total`) are emitted per-pod and aggregated via `sum(rate(...))` in Grafana — this is the standard Prometheus pattern, no double-counting concern.

---

## Rule engine

### Interface

```go
// internal/rules/rule.go
package rules

import kedav1alpha1 "github.com/kedacore/keda/v2/apis/keda/v1alpha1"

type Severity string
const (
    SeverityError Severity = "error"
    SeverityWarn  Severity = "warn"
    SeverityOff   Severity = "off"
)

// Target wraps either a ScaledObject or a ScaledJob — both expose
// Spec.Triggers []ScaleTriggers, so rules don't need to type-switch.
type Target struct {
    Kind      string                       // "ScaledObject" | "ScaledJob"
    Namespace string
    Name      string
    Triggers  []kedav1alpha1.ScaleTriggers
}

type Violation struct {
    RuleID       string  // e.g. "KEDA001"
    TriggerIndex int     // -1 if violation is at object level
    TriggerType  string  // e.g. "cpu", "memory"; "" if object-level
    Field        string  // e.g. "metadata.type"
    Message      string  // human-readable, no PII
    FixHint      string  // one-line "do this instead"
    // No Severity field — effective severity is resolved at the call site by
    // Config.EffectiveSeverity(ruleID, namespace, nsLabels).
}

type Rule interface {
    ID() string
    BuiltinDefaultSeverity() Severity   // fallback when CM has no entry for this rule
    Lint(t Target) []Violation
}

// Registry is built at package init; webhook + controller share one instance.
var Registry = []Rule{
    &CpuMemoryMetadataType{},   // KEDA001
}

// LintAll runs every registered rule against the target.
// Webhook handler and controller reconciler both call this.
func LintAll(t Target) []Violation {
    var out []Violation
    for _, r := range Registry {
        out = append(out, r.Lint(t)...)
    }
    return out
}
```

`Severity` and its constants live in package `rules` (leaf package, no dependencies on `config`). Package `config` imports `rules` and uses the same type — there is **one** `Severity` type in the codebase. This avoids the circular dependency that would arise if `config` owned the type and `Rule.BuiltinDefaultSeverity()` had to import `config`.

### KEDA001 — CPU/Memory `metadata.type`

```go
// internal/rules/keda001.go
type CpuMemoryMetadataType struct{}

func (*CpuMemoryMetadataType) ID() string                       { return "KEDA001" }
func (*CpuMemoryMetadataType) BuiltinDefaultSeverity() Severity { return SeverityError }

func (*CpuMemoryMetadataType) Lint(t Target) []Violation {
    var out []Violation
    for i, tr := range t.Triggers {
        if tr.Type != "cpu" && tr.Type != "memory" { continue }
        if _, ok := tr.Metadata["type"]; !ok { continue }
        out = append(out, Violation{
            RuleID:       "KEDA001",
            TriggerIndex: i,
            TriggerType:  tr.Type,
            Field:        "metadata.type",
            Message: fmt.Sprintf(
                "trigger[%d] (type=%s): metadata.type is deprecated since KEDA 2.10 and removed in 2.18",
                i, tr.Type),
            FixHint: fmt.Sprintf(
                "Use triggers[%d].metricType: %s instead.", i, tr.Metadata["type"]),
        })
    }
    return out
}
```

The rule flags `metadata.type` even if `metricType` is also set — KEDA 2.18 removes the field, so any `metadata.type: ...` will be unmarshal-rejected. It also covers all combinations for completeness.

### Webhook decision algorithm

```go
// internal/webhook/handler.go (sketch)

func (h *Handler) decide(req *admission.Request, oldT, newT *Target) admission.Response {
    cfg := h.configStore.Load().(*config.Config)
    nsLabels := h.nsCache.Get(req.Namespace)

    newV := rules.LintAll(*newT)
    var oldV []rules.Violation
    if oldT != nil {
        oldV = rules.LintAll(*oldT)
    }

    added := diffByKey(newV, oldV)        // key = (RuleID, TriggerType, Field)

    // Reject only when CREATE has any error-severity violation,
    // or UPDATE adds a new error-severity violation.
    var rejecting []rules.Violation
    candidates := newV
    if oldT != nil {
        candidates = added
    }
    for _, v := range candidates {
        if cfg.EffectiveSeverity(v.RuleID, req.Namespace, nsLabels) == rules.SeverityError {
            rejecting = append(rejecting, v)
        }
    }
    if len(rejecting) > 0 {
        h.metrics.IncRejects(req.Namespace, req.Kind.Kind, rejecting, req.Operation)
        return admission.Denied(formatRejection(rejecting, cfg.RejectMessageURL))
    }

    // Allow, but attach warnings for any non-`off` violation present in newV.
    var warnings []string
    for _, v := range newV {
        sev := cfg.EffectiveSeverity(v.RuleID, req.Namespace, nsLabels)
        if sev == rules.SeverityOff { continue }
        warnings = append(warnings, formatWarning(v))
    }
    h.metrics.IncWarnings(req.Namespace, req.Kind.Kind, newV)
    return admission.Allowed("").WithWarnings(warnings...)
}
```

The diff key is `(RuleID, TriggerType, Field)`. `TriggerIndex` is deliberately **not** part of the key: rejecting an UPDATE solely because the user reordered `triggers[]` would punish movement that doesn't introduce new debt. Trade-off: if a user changes `triggers[0]` from `cpu` to `memory` while keeping `metadata.type`, the violation's `TriggerType` changes from `cpu` to `memory` — that key *will* be classified as added and the UPDATE will be rejected. This is the desired behaviour: the user introduced a deprecated `metadata.type` on a trigger that didn't have one before, regardless of index.

`TriggerIndex` is still present on the `Violation` struct for the purpose of metric labels, warning messages, and rejection messages — it's only excluded from the additive-only diff key.

### Controller reconcile loop

- One reconciler per CRD (`ScaledObjectReconciler`, `ScaledJobReconciler`), both backed by the shared rule engine.
- **Runs only on the leader replica** (controller-runtime Manager `LeaderElection: true`). Webhook handler runs on all replicas.
- On every event for a watched object: lint → for each violation, set `keda_deprecation_violations{...} = 1` with `severity` resolved through the config store.
- On object deletion: clear the gauge labels for that object.
- Watches `ConfigMap` in own namespace; on CM change, trigger a re-lint of all watched objects (so gauge `severity` labels reflect the new effective severity within the same reconcile cycle).
- Watches `Namespace`; on namespace label change, re-lint affected objects.

#### Gauge label-set bookkeeping (avoid ghost series on severity flip)

The `severity` label is part of the gauge's series identity, so a violation whose effective severity flips (e.g. CM hot-reload moves a namespace from `error` → `warn`) would otherwise leave the prior `severity="error"` series asserted at `1` forever — observable in dashboards as ghost violations.

The reconciler maintains a per-object map of last-emitted label sets:

```go
// keyed by client.ObjectKey of the SO/SJ; value is the set of
// full label maps the reconciler asserted on its previous pass.
lastLabels map[types.NamespacedName][]prometheus.Labels
```

On each reconcile pass for an object:

1. Compute the new set of label maps from the current lint + config resolution.
2. For every label map in `lastLabels[obj]` that is **not** in the new set, call `gauge.DeleteLabelValues(...)`.
3. For every label map in the new set, call `gauge.With(...).Set(1)`.
4. Replace `lastLabels[obj]` with the new set.

On object deletion: delete every label map in `lastLabels[obj]`, then drop the entry.

This keeps gauge state exactly equal to the cluster's current violation set after every CM reload, namespace label change, or trigger edit — no ghost series, no double-counting, and no need to enumerate "all possible severity values" defensively.

---

## Metrics

Two families: gauge (current state of the cluster) and counters (events).

### Gauge — current violations

```
keda_deprecation_violations{
  namespace,           // e.g. "demo-cpu"
  kind,                // "ScaledObject" | "ScaledJob"
  name,                // e.g. "cpu-demo"
  trigger_index,       // "0", "1", ... ("-1" if object-level)
  trigger_type,        // "cpu" / "memory" / ""
  rule_id,             // "KEDA001"
  severity,            // EFFECTIVE severity, post-CM-resolution: "error"|"warn"|"off"
} = 1
```

- One time series per violation. Value is always `1` (presence).
- Lifecycle: controller calls `DeleteLabelValues(...)` for every label map that was emitted on the previous reconcile but is no longer in the current label set (object deleted, violation gone, OR effective severity flipped). See *Gauge label-set bookkeeping* above.
- Cardinality bound: `sum_over_objects(violating_triggers)`. Bounded by ScaledObject count × triggers-per-object × rules. For a fleet with thousands of SOs, expect low thousands of series.
- `severity="off"` series are still emitted so that a dashboard can show fleet-wide debt even in exempted namespaces. Default Grafana queries filter `severity != "off"`.

### Counters — admission events

```
keda_deprecation_admission_rejects_total{
  namespace, kind, rule_id, operation,    // operation: "CREATE" | "UPDATE"
}

keda_deprecation_admission_warnings_total{
  namespace, kind, rule_id,
}
```

- Cardinality is `O(namespace × rule_id)`, small.
- Used for "rejects per week by namespace" and "is enforcement starting to bite" dashboards.

### Counters — config health

```
keda_deprecation_config_reloads_total{result}    // "success" | "error"
keda_deprecation_config_reload_errors_total      // shorthand alias for {result="error"}
keda_deprecation_config_generation                // gauge, monotonic, increments per successful reload
```

---

## Configuration

### ConfigMap schema

A single ConfigMap, in the same namespace as the webhook Deployment, named `keda-deprecation-webhook-config`, with a `config.yaml` data key:

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: keda-deprecation-webhook-config
  namespace: keda-system
data:
  config.yaml: |
    rules:
      - id: KEDA001
        defaultSeverity: error
        namespaceOverrides:
          # First match wins. Each entry has EXACTLY ONE of `names` OR `labelSelector`.
          - names: ["sandbox", "experiment-*"]   # glob supported
            severity: warn
          - labelSelector:
              matchLabels:
                migration-phase: in-progress
              matchExpressions:
                - { key: tier, operator: In, values: [legacy] }
            severity: warn
          - names: ["frozen-team"]
            severity: off
```

### Severity semantics

| Severity | Webhook on CREATE | Webhook on UPDATE (additive) | Warning attached | Metric emitted |
| --- | --- | --- | --- | --- |
| `error` | reject | reject if diff adds violation | yes (existing-but-still-bad warns) | yes, `severity="error"` |
| `warn`  | allow | allow | yes | yes, `severity="warn"` |
| `off`   | allow | allow | no | yes, `severity="off"` |

`off` deliberately still emits the metric so exempted namespaces remain visible in fleet-wide queries — never silent.

### Resolution

```go
// internal/config/resolver.go
func (c *Config) EffectiveSeverity(ruleID, ns string, nsLabels map[string]string) Severity {
    rule, ok := c.findRule(ruleID)
    if !ok {
        return c.builtinDefault(ruleID)   // CM doesn't list this rule → use binary default
    }
    for _, o := range rule.NamespaceOverrides {   // first match wins; user-controlled order
        if o.matches(ns, nsLabels) {
            return o.Severity
        }
    }
    return rule.DefaultSeverity
}
```

Webhook handler and controller both call this single function. Behavior consistency between admission and gauge is therefore guaranteed.

### Override matcher (Design A)

Each `namespaceOverrides[]` entry has **exactly one** of:

- `names: []string` — exact name match, with shell-glob (`*`, `?`) supported
- `labelSelector: metav1.LabelSelector` — standard Kubernetes label selector

Validation rejects entries with both or neither set. Multiple entries are evaluated top-to-bottom; first match wins. Operators control precedence by ordering — most-specific entries first.

This is intentionally less expressive than allowing `names` and `labelSelector` simultaneously (AND). The 90% case is "by name OR by label, not both". If a use case truly needs the conjunction, the workaround is to add a label to the relevant namespaces and select on that.

### Hot reload

```
ConfigMap CM
   │
   │ (controller-runtime informer watches this single CM)
   ▼
configWatcher.Reconcile()
   ├─ parse data["config.yaml"]  (yaml.UnmarshalStrict, schema validation)
   ├─ on validation error:
   │    log ERROR + bump keda_deprecation_config_reload_errors_total
   │    create Event on the CM ("Invalid: ...")
   │    keep last good config (no-op)
   └─ on success:
        atomic.Value.Store(newConfig)
        bump keda_deprecation_config_generation
        log INFO "config reloaded, generation=N"
        enqueue ALL ScaledObjects + ScaledJobs to re-lint
        (gauge severity labels flip immediately, not on next informer event)
```

The webhook handler reads `cfg := configStore.Load().(*Config)` once per admission request. Atomic-pointer swap; no locking.

### Edge cases

| Situation | Behavior |
| --- | --- |
| CM does not exist | Use binary built-in defaults (KEDA001 `error`, no overrides). Log WARNING. Pod still ready |
| Initial CM YAML invalid | Pod fails `/readyz`, CrashLoopBackOff. Operator must fix |
| Runtime CM becomes invalid | Keep last good config. Log + Event + counter. No crash |
| CM references unknown `id: KEDAxxx` | Log + skip that entry. Do not reject the whole config. Forward-compat: a new CM can roll to all clusters before an image bump |
| Rule registered in binary but not in CM | Use that rule's `BuiltinDefaultSeverity()` |
| Namespace matches multiple overrides | First match wins. Operators control order — same mental model as NetworkPolicy or nginx location blocks |

### RBAC additions

```yaml
- apiGroups: [""]
  resources: ["configmaps"]
  resourceNames: ["keda-deprecation-webhook-config"]
  verbs: ["get", "list", "watch"]
- apiGroups: [""]
  resources: ["namespaces"]
  verbs: ["get", "list", "watch"]   # for labelSelector matching
- apiGroups: [""]
  resources: ["events"]
  verbs: ["create", "patch"]        # for invalid-config Events on the CM
- apiGroups: ["keda.sh"]
  resources: ["scaledobjects", "scaledjobs"]
  verbs: ["get", "list", "watch"]   # controller reconcile
- apiGroups: ["coordination.k8s.io"]
  resources: ["leases"]
  verbs: ["get", "list", "watch", "create", "update", "patch"]   # leader election
```

---

## Lab integration

### Repository layout

```
keda-labs/
├── cmd/keda-deprecation-webhook/main.go        ← NEW (entrypoint)
├── internal/
│   ├── config/                                 ← NEW (loader, watcher, resolver)
│   ├── rules/                                  ← NEW (Rule interface + KEDA001)
│   ├── webhook/                                ← NEW (admission handler)
│   ├── controller/                             ← NEW (SO + SJ informers)
│   └── metrics/                                ← NEW (Prometheus collectors)
├── manifests/
│   ├── demo-deprecated/                        ← NEW — deprecated SO, expects reject
│   ├── demo-deprecated-warn/                   ← NEW — deprecated SO in warn-override ns
│   └── keda-deprecation-webhook/               ← NEW — namespace, deployment, svc, rbac, cm, cert, vwc
├── scripts/
│   ├── install-cert-manager.sh                 ← NEW
│   ├── install-webhook.sh                      ← NEW (build + kind load + apply)
│   └── verify-webhook.sh                       ← NEW (health + admission demo asserts)
├── grafana/dashboards/keda-deprecations.json   ← NEW
├── prometheus/values.yaml                      ← MODIFIED (add 3 alert rules)
├── scripts/up.sh                               ← MODIFIED (insert install-cert-manager + install-webhook)
├── go.mod / go.sum / Dockerfile                ← NEW
└── Makefile                                    ← MODIFIED (5 new targets)
```

### cert-manager Issuer + Certificate

```yaml
# manifests/keda-deprecation-webhook/certificate.yaml
apiVersion: cert-manager.io/v1
kind: Issuer
metadata: { name: kdw-selfsigned, namespace: keda-system }
spec: { selfSigned: {} }
---
apiVersion: cert-manager.io/v1
kind: Certificate
metadata: { name: kdw-serving-cert, namespace: keda-system }
spec:
  secretName: kdw-tls
  duration: 8760h          # 1 year
  renewBefore: 720h        # 30 days
  dnsNames:
    - keda-deprecation-webhook.keda-system.svc
    - keda-deprecation-webhook.keda-system.svc.cluster.local
  issuerRef: { name: kdw-selfsigned, kind: Issuer }
```

### ValidatingWebhookConfiguration

```yaml
apiVersion: admissionregistration.k8s.io/v1
kind: ValidatingWebhookConfiguration
metadata:
  name: keda-deprecation-webhook
  annotations:
    cert-manager.io/inject-ca-from: keda-system/kdw-serving-cert
webhooks:
  - name: vkdw.keda.sh
    failurePolicy: Ignore
    sideEffects: None
    admissionReviewVersions: ["v1"]
    timeoutSeconds: 5
    matchPolicy: Equivalent
    rules:
      - apiGroups: ["keda.sh"]
        apiVersions: ["v1alpha1"]
        operations: ["CREATE", "UPDATE"]
        resources: ["scaledobjects", "scaledjobs"]
    clientConfig:
      service:
        namespace: keda-system
        name: keda-deprecation-webhook
        path: /validate-keda-sh-v1alpha1
        port: 443
```

### Deployment hygiene

- Service annotated `prometheus.io/scrape=true,port=8080,path=/metrics` — picked up by the existing `kubernetes-service-endpoints` Prometheus job (same pattern as KEDA in this lab).
- Service ports:
  - `443 → 9443` (webhook HTTPS): apiserver-friendly external port `443`, container listens on `9443`. The `ValidatingWebhookConfiguration.clientConfig.service.port` references `443`.
  - `8080 → 8080` (metrics + probes, plain HTTP).
- 2 replicas + PDB (`maxUnavailable: 1`) so admission stays available during rolling updates.
- `livenessProbe` `/healthz`; `readinessProbe` `/readyz` (fails until cert is mounted and config loaded — prevents serving admission before ready).
- Resource requests `50m / 64Mi`, limits `200m / 256Mi`.
- Env:
  ```yaml
  - name: REJECT_MESSAGE_URL
    value: ""    # placeholder — operator sets to internal migration runbook URL
  - name: NAMESPACE
    valueFrom: { fieldRef: { fieldPath: metadata.namespace } }
  ```

### Makefile targets

```makefile
install-cert-manager:
	@CLUSTER_NAME=$(CLUSTER_NAME) ./scripts/install-cert-manager.sh

build-webhook:
	@docker build -t keda-deprecation-webhook:dev -f Dockerfile .
	@kind load docker-image keda-deprecation-webhook:dev --name $(CLUSTER_NAME)

install-webhook: build-webhook
	@CLUSTER_NAME=$(CLUSTER_NAME) ./scripts/install-webhook.sh

demo-deprecated:
	@kubectl apply -f manifests/demo-deprecated/ ; true     # expected to print reject

demo-deprecated-warn:
	@kubectl apply -f manifests/demo-deprecated-warn/

verify-webhook:
	@CLUSTER_NAME=$(CLUSTER_NAME) ./scripts/verify-webhook.sh
```

Updated `make up` ordering:

```
prereqs → create-cluster → label-zones → install-metrics-server →
install-monitoring → install-keda → install-cert-manager → install-webhook →
install-grafana → deploy-demo
```

### Demo workloads

- **`manifests/demo-deprecated/`** — namespace `demo-deprecated`, no override → falls through to `defaultSeverity: error`. `make demo-deprecated` triggers a webhook rejection. Demonstrates the admission path.
- **`manifests/demo-deprecated-warn/`** — namespace `demo-deprecated-warn`, covered by lab default CM with `severity: warn`. `make demo-deprecated-warn` succeeds, kubectl prints a warning, and `keda_deprecation_violations{namespace="demo-deprecated-warn", severity="warn"}` becomes 1. Demonstrates the controller path.

### Lab default ConfigMap

```yaml
# manifests/keda-deprecation-webhook/configmap.yaml
data:
  config.yaml: |
    rules:
      - id: KEDA001
        defaultSeverity: error
        namespaceOverrides:
          - names: ["demo-deprecated-warn"]
            severity: warn
```

Editing this CM and `kubectl apply` exercises the hot-reload path on the live lab.

### Grafana dashboard `KEDA Deprecations` (UID `keda-deprecations`)

Same `Datasource` / `Prodsuite` / `Namespace` template variables as the existing two dashboards. Panels:

1. **Stat** — count of `severity="error"` violations (KPI).
2. **Stat** — count of `severity="warn"` violations.
3. **Stat** — count of `severity="off"` violations (exempted but extant debt).
4. **Time series** — violation count over time, grouped by severity (migration progress).
5. **Table** — per-violation row: `namespace | kind | name | trigger_index | trigger_type | rule_id | severity`. Pulled directly from the gauge.
6. **Counter rate (7d)** — admission rejects by namespace + rule_id.
7. **Counter rate (7d)** — admission warnings by namespace + rule_id.
8. **Stat** — `keda_deprecation_config_generation` (last successful reload).
9. **Stat** — `keda_deprecation_config_reload_errors_total` 7d total (>0 → red).

### Alert rules (added to `prometheus/values.yaml`, group `keda-deprecations`)

```yaml
- alert: KedaDeprecationWebhookDown
  expr: up{namespace="keda-system", service="keda-deprecation-webhook"} == 0
  for: 5m
  labels: { severity: critical }
  annotations:
    summary: keda-deprecation-webhook is unreachable
    description: |
      failurePolicy=Ignore — deprecated specs may slip through during this outage.
      Controller path will eventually surface them via keda_deprecation_violations.

- alert: KedaDeprecationConfigReloadFailing
  expr: increase(keda_deprecation_config_reload_errors_total[10m]) > 0
  for: 0m
  labels: { severity: warning }
  annotations:
    summary: keda-deprecation-webhook ConfigMap is invalid
    description: |
      Last good config still in use. Inspect events on the ConfigMap and fix.

- alert: KedaDeprecationErrorViolationsPresent
  expr: sum(keda_deprecation_violations{severity="error"}) > 0
  for: 1h
  labels: { severity: warning }
  annotations:
    summary: '{{ $value }} ScaledObject(s) still have severity=error deprecation violations'
    description: |
      These will break on KEDA 2.18. Review the KEDA Deprecations dashboard for the list.
```

---

## Failure modes

| Scenario | Webhook behavior | Controller behavior | Net result |
| --- | --- | --- | --- |
| Webhook pod down (all replicas) | apiserver sees connection refused; `failurePolicy=Ignore` allows | also down (same Pod) | Deprecated SO can slip through. Once the pod recovers, controller's list-watch re-emits gauges. Alert fires after 5 min |
| ConfigMap deleted | Informer notifies; falls back to binary defaults (KEDA001 `error`, no overrides) | same | Equivalent to "no overrides" — may suddenly start blocking previously-exempt namespaces. Mitigation: edit the CM, don't delete it |
| ConfigMap YAML broken | Keeps last good config; counter increments; Event on the CM | same | Operator notified by alert + `kubectl describe cm` |
| cert-manager Certificate expires unrenewed | apiserver TLS handshake fails; `failurePolicy=Ignore` allows | unaffected | Same as webhook down. `renewBefore: 30d` ensures normal autorenewal; expiration timestamp panel on dashboard |
| Bulk reconcile (cluster restart, full informer resync) | unaffected | Lint and gauge update via worker pool | Bounded — lint is in-memory, microseconds per object |
| Webhook timeout (>5s) | apiserver `failurePolicy=Ignore` allows | unaffected | Should not happen — lint is O(triggers) per object, low milliseconds |

---

## Multi-cluster rollout plan

1. **Phase 0 — Lab validation.** Spec implemented; `make up` succeeds; `make demo-deprecated` produces expected reject; `make demo-deprecated-warn` produces expected warning + gauge series; all three alerts can be triggered manually; all three dashboards render.

2. **Phase 1 — Fleet-wide warn mode.** Roll the binary to all clusters via GitOps with the initial CM:

   ```yaml
   rules:
     - id: KEDA001
       defaultSeverity: warn
   ```

   Run for 1–2 weeks. Inventory builds up in dashboards; teams self-identify and start fixing.

3. **Phase 2 — Per-cluster enforcement.** Cluster by cluster (dev → staging → low-risk prod → high-risk prod), flip `defaultSeverity` to `error` and add per-namespace overrides as needed. Each cluster's CM is independently rollback-able by reverting the GitOps commit.

4. **Phase 3 — KEDA 2.18 upgrade.** On each cluster, only proceed once `KedaDeprecationErrorViolationsPresent` is silent.

The CM-based design means **enforcement level is decoupled from binary release** — every phase is reversible in seconds via `kubectl apply` of a previous CM.

---

## Testing strategy

**Unit:** `internal/rules/keda001_test.go` — table-driven, covers cpu/memory triggers with and without `metadata.type`, mixed (`metadata.type` + `metricType`), non-cpu/non-memory triggers (must produce 0 violations), multi-trigger objects (correct `trigger_index`).

**Unit:** `internal/config/resolver_test.go` — covers all three override matcher styles, first-match-wins ordering, unknown rule IDs (logged, skipped), missing CM (built-in defaults), invalid CM (last-good preserved).

**Integration:** envtest brings up apiserver + etcd + webhook + controller; applies SO/SJ YAMLs; asserts:
- CREATE in `error` namespace → admission rejected (with rule ID and fix hint in the message).
- CREATE in `warn` namespace → allowed; `AdmissionResponse.Warnings` populated.
- UPDATE on existing-bad object that doesn't add a violation → allowed + warning.
- UPDATE that only **reorders** existing-bad triggers (changes `TriggerIndex` but not `TriggerType`/`Field` of any violation) → allowed + warning. Pins the diff-key choice.
- UPDATE that adds a violation → rejected.
- CM hot-reload that flips a namespace from `error` to `warn` → after one reconcile cycle, `keda_deprecation_violations{...,severity="error"}` for that namespace is **deleted** and only `severity="warn"` remains. Pins the gauge label-set bookkeeping.
- After admission, `/metrics` exposes the expected series.

**Lab E2E:** `make verify-webhook` runs the demo workloads and asserts the expected `kubectl` outputs and metric values.

---

## Out of scope / future work

- **Helm chart** for production packaging — separate spec.
- **`KedaDeprecationPolicy` CRD** if per-cluster CM management becomes insufficient.
- **Additional rules** (KEDA002, KEDA003 …) — to be backlogged once KEDA001 + framework is in.
- **Webhook self-SLO** (admission p99 latency, config reload latency) — instrument basics first, define targets later.
- **Multi-arch image builds** — needed at chart time; lab is single-arch via `kind load`.
- **CEL/DSL rule definition** — explicitly rejected; would re-implement Kyverno.
- **Mutating webhook** — explicitly rejected; would hide debt.
