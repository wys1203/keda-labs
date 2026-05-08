# keda-deprecation-webhook Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build the `keda-deprecation-webhook` (KDW) — a Kubernetes ValidatingWebhook + controller that blocks/inventories deprecated KEDA spec fields (starting with KEDA001: cpu/memory `metadata.type`) and ship it as part of the keda-labs lab.

**Architecture:** One Go binary, two replicas, leader-elected controller (gauge emission) + per-pod webhook server. Rule engine is a registry of `Rule` interfaces; webhook and controller both call `rules.LintAll(target)`. Severity is resolved through a hot-reloadable ConfigMap whose changes propagate via informer + per-object label-set bookkeeping (no ghost gauge series). cert-manager issues the webhook TLS cert; a `ValidatingWebhookConfiguration` carries `cert-manager.io/inject-ca-from`. Failure mode is `Ignore` — controller path provides eventual visibility.

**Tech Stack:** Go 1.23, sigs.k8s.io/controller-runtime, github.com/kedacore/keda/v2 (CRD types), github.com/prometheus/client_golang, sigs.k8s.io/yaml, sigs.k8s.io/controller-runtime/pkg/envtest (integration tests), kind + helm + cert-manager (lab).

**Spec:** `docs/superpowers/specs/2026-05-05-keda-deprecation-webhook-design.md` (commit `fb7a5a2`).

**Convention notes for the implementer:**
- The repo's existing namespace for KEDA is `platform-keda`. The webhook lives in a separate `keda-system` namespace per the spec — don't merge them.
- cert-manager is already installed via `scripts/install-keda.sh` (which calls `scripts/install-cert-manager.sh`). Don't add a separate install step in `up.sh`.
- An existing `manifests/legacy-cpu/` ScaledObject (`legacy-cpu/cpu-legacy`) is already a deprecated CPU offender. **Reuse it as the warn-mode demo target** by adding `legacy-cpu` to the lab CM's `namespaceOverrides` with `severity: warn`. This deviates from the spec's `demo-deprecated-warn/` naming but avoids duplicating fixtures.
- The reject-mode demo (`demo-deprecated/`) is new and exists only to demonstrate the admission rejection.
- Existing Prometheus uses `kubernetes-service-endpoints` job auto-discovery via `prometheus.io/scrape=true` annotations. The webhook Service must carry those annotations.
- Existing Prometheus alerts live in `prometheus/values.yaml` under `serverFiles.alerting_rules.yml.groups`. Add a new `keda-deprecations` group.
- Existing dashboards are provisioned via the `grafana-dashboards` ConfigMap (per project memory). Adding a new dashboard JSON file requires regenerating that CM and rolling Grafana.

---

## File structure

### Go source (new)

| Path | Responsibility |
|---|---|
| `go.mod`, `go.sum` | Module declaration, deps |
| `Dockerfile` | Multi-stage build, distroless runtime |
| `cmd/keda-deprecation-webhook/main.go` | Entrypoint, controller-runtime manager wiring, leader election, webhook server registration |
| `internal/rules/rule.go` | `Severity` type + constants, `Target`, `Violation`, `Rule` interface, `Registry`, `LintAll` |
| `internal/rules/keda001.go` | `CpuMemoryMetadataType` rule |
| `internal/rules/keda001_test.go` | Table-driven unit tests for KEDA001 |
| `internal/config/schema.go` | `Config`, `RuleConfig`, `NamespaceOverride`, `Match()` |
| `internal/config/loader.go` | `ParseYAML([]byte) (*Config, error)` with strict unmarshalling + validation |
| `internal/config/loader_test.go` | Loader unit tests |
| `internal/config/resolver.go` | `Config.EffectiveSeverity(ruleID, ns, nsLabels)` |
| `internal/config/resolver_test.go` | Resolver unit tests |
| `internal/config/store.go` | `Store` wrapping `atomic.Value`; `Load`/`Store`/`Generation` |
| `internal/config/watcher.go` | controller-runtime ConfigMap reconciler that updates the store, bumps generation, and re-enqueues SOs/SJs |
| `internal/webhook/diff.go` | `DiffByKey(new, old []rules.Violation) (added []rules.Violation)` keyed by `(RuleID, TriggerType, Field)` |
| `internal/webhook/diff_test.go` | Diff unit tests including reordering case |
| `internal/webhook/handler.go` | `Handler.Handle(ctx, req)` admission decision per spec algorithm |
| `internal/webhook/handler_test.go` | Handler unit tests (table-driven) |
| `internal/controller/emitter.go` | `Emitter` with per-object `lastLabels` bookkeeping (`Sync(obj, newLabels)`, `Forget(obj)`) |
| `internal/controller/emitter_test.go` | Emitter unit tests including severity-flip case |
| `internal/controller/scaledobject_reconciler.go` | Reconciles `ScaledObject` + namespace cache + emitter |
| `internal/controller/scaledjob_reconciler.go` | Same for `ScaledJob` |
| `internal/controller/namespace_reconciler.go` | On Namespace label change, enqueue all SO/SJ in that namespace |
| `internal/metrics/metrics.go` | Prometheus collectors: violations gauge, admission rejects/warnings counters, config reload counters/gauge |
| `internal/metrics/labels.go` | Helpers to build label maps (so emitter and handler share the schema) |
| `test/integration/suite_test.go` | envtest harness (apiserver + etcd) |
| `test/integration/webhook_test.go` | Integration test cases per spec testing strategy |

### Manifests + scripts (new)

| Path | Responsibility |
|---|---|
| `manifests/keda-deprecation-webhook/namespace.yaml` | `keda-system` ns |
| `manifests/keda-deprecation-webhook/rbac.yaml` | SA, Role/RB (configmaps + events in own ns), ClusterRole/CRB (SO/SJ + namespaces, leases) |
| `manifests/keda-deprecation-webhook/certificate.yaml` | cert-manager `Issuer` (selfSigned) + `Certificate` |
| `manifests/keda-deprecation-webhook/configmap.yaml` | Lab default config: KEDA001 default `error`, `legacy-cpu` override `warn` |
| `manifests/keda-deprecation-webhook/deployment.yaml` | 2 replicas, probes, resource limits, env |
| `manifests/keda-deprecation-webhook/service.yaml` | 443→9443 (webhook), 8080→8080 (metrics+probes), Prometheus annotations |
| `manifests/keda-deprecation-webhook/pdb.yaml` | maxUnavailable: 1 |
| `manifests/keda-deprecation-webhook/validatingwebhookconfiguration.yaml` | VWC with `cert-manager.io/inject-ca-from`, scope SO+SJ |
| `manifests/demo-deprecated/namespace.yaml` | `demo-deprecated` ns (no override → falls through to default error) |
| `manifests/demo-deprecated/deployment.yaml` | Tiny CPU consumer pod (so the SO has a target) |
| `manifests/demo-deprecated/scaledobject.yaml` | CPU SO with deprecated `metadata.type` (expects rejection) |
| `scripts/install-webhook.sh` | Build image, kind-load, kubectl-apply manifests, wait for ready |
| `scripts/verify-webhook.sh` | E2E checks: pod ready, /healthz, expected reject + warn admission, expected metrics |

### Modified

| Path | Change |
|---|---|
| `Makefile` | Add `build-webhook`, `install-webhook`, `verify-webhook`, `demo-deprecated` targets + corresponding `.PHONY` |
| `scripts/up.sh` | Insert `install-webhook.sh` between KEDA install and `deploy-demo.sh` |
| `prometheus/values.yaml` | Add `keda-deprecations` group with 3 alerts |
| `grafana/dashboards/keda-deprecations.json` | New dashboard file |
| `scripts/install-grafana.sh` (or the dashboards CM step) | Pick up the new dashboard JSON |
| `README.md` | One-paragraph mention + link to spec |

---

## Tasks

### Task 1: Go module bootstrap

**Files:**
- Create: `go.mod`
- Create: `cmd/keda-deprecation-webhook/main.go`
- Create: `.gitignore` (if not present)

- [ ] **Step 1: Initialize Go module**

```bash
go mod init github.com/wys1203/keda-labs
```

- [ ] **Step 2: Create skeleton main.go**

```go
// cmd/keda-deprecation-webhook/main.go
package main

import (
	"fmt"
	"os"
)

func main() {
	fmt.Fprintln(os.Stderr, "keda-deprecation-webhook: stub, not yet wired")
	os.Exit(0)
}
```

- [ ] **Step 3: Add baseline deps and tidy**

```bash
go get \
  sigs.k8s.io/controller-runtime@v0.18.4 \
  k8s.io/api@v0.30.3 \
  k8s.io/apimachinery@v0.30.3 \
  k8s.io/client-go@v0.30.3 \
  github.com/kedacore/keda/v2@v2.16.1 \
  github.com/prometheus/client_golang@v1.19.1 \
  sigs.k8s.io/yaml@v1.4.0 \
  github.com/stretchr/testify@v1.9.0
go mod tidy
```

- [ ] **Step 4: Verify build**

Run: `go build ./...`
Expected: exits 0, no output.

- [ ] **Step 5: Add `bin/` to `.gitignore` if missing**

Append to `.gitignore` (create file if absent):
```
/bin/
```

- [ ] **Step 6: Commit**

```bash
git add go.mod go.sum cmd/keda-deprecation-webhook/main.go .gitignore
git commit -m "feat(kdw): bootstrap Go module + main stub"
```

---

### Task 2: Rule engine — interface and registry

**Files:**
- Create: `internal/rules/rule.go`
- Create: `internal/rules/rule_test.go`

- [ ] **Step 1: Write the failing test**

```go
// internal/rules/rule_test.go
package rules

import (
	"testing"

	"github.com/stretchr/testify/assert"
)

type fakeRule struct {
	id  string
	out []Violation
}

func (f *fakeRule) ID() string                       { return f.id }
func (f *fakeRule) BuiltinDefaultSeverity() Severity { return SeverityError }
func (f *fakeRule) Lint(_ Target) []Violation        { return f.out }

func TestLintAll_RunsEveryRegisteredRule(t *testing.T) {
	old := Registry
	t.Cleanup(func() { Registry = old })

	a := &fakeRule{id: "A", out: []Violation{{RuleID: "A", Field: "x"}}}
	b := &fakeRule{id: "B", out: []Violation{{RuleID: "B", Field: "y"}}}
	Registry = []Rule{a, b}

	got := LintAll(Target{Kind: "ScaledObject"})

	assert.Len(t, got, 2)
	assert.Equal(t, "A", got[0].RuleID)
	assert.Equal(t, "B", got[1].RuleID)
}

func TestSeverity_Constants(t *testing.T) {
	assert.Equal(t, Severity("error"), SeverityError)
	assert.Equal(t, Severity("warn"), SeverityWarn)
	assert.Equal(t, Severity("off"), SeverityOff)
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `go test ./internal/rules/... -run TestLintAll -v`
Expected: FAIL — package does not compile (missing types).

- [ ] **Step 3: Implement rule.go**

```go
// internal/rules/rule.go
//
// Rule engine primitives shared by the webhook and the controller.
//
// Severity lives in this leaf package on purpose: package config imports
// rules, not the other way around. That avoids a cycle in
// Rule.BuiltinDefaultSeverity().
package rules

import (
	kedav1alpha1 "github.com/kedacore/keda/v2/apis/keda/v1alpha1"
)

type Severity string

const (
	SeverityError Severity = "error"
	SeverityWarn  Severity = "warn"
	SeverityOff   Severity = "off"
)

// Target wraps either a ScaledObject or a ScaledJob. Both expose
// Spec.Triggers []ScaleTriggers, so rules don't need to type-switch.
type Target struct {
	Kind      string // "ScaledObject" | "ScaledJob"
	Namespace string
	Name      string
	Triggers  []kedav1alpha1.ScaleTriggers
}

type Violation struct {
	RuleID       string
	TriggerIndex int    // -1 if violation is at object level
	TriggerType  string // e.g. "cpu", "memory"; "" if object-level
	Field        string // e.g. "metadata.type"
	Message      string
	FixHint      string
}

type Rule interface {
	ID() string
	BuiltinDefaultSeverity() Severity
	Lint(t Target) []Violation
}

// Registry is mutated only at package init by individual rule files.
var Registry []Rule

func LintAll(t Target) []Violation {
	var out []Violation
	for _, r := range Registry {
		out = append(out, r.Lint(t)...)
	}
	return out
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `go test ./internal/rules/... -v`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add internal/rules/rule.go internal/rules/rule_test.go
git commit -m "feat(kdw): rule engine interface and registry"
```

---

### Task 3: KEDA001 — cpu/memory metadata.type rule

**Files:**
- Create: `internal/rules/keda001.go`
- Create: `internal/rules/keda001_test.go`

- [ ] **Step 1: Write the failing tests**

```go
// internal/rules/keda001_test.go
package rules

import (
	"testing"

	"github.com/stretchr/testify/assert"
	kedav1alpha1 "github.com/kedacore/keda/v2/apis/keda/v1alpha1"
)

func TestKEDA001_CpuWithMetadataType_FlagsViolation(t *testing.T) {
	r := &CpuMemoryMetadataType{}
	target := Target{
		Kind:      "ScaledObject",
		Namespace: "demo",
		Name:      "x",
		Triggers: []kedav1alpha1.ScaleTriggers{
			{Type: "cpu", Metadata: map[string]string{"type": "Utilization", "value": "50"}},
		},
	}

	got := r.Lint(target)

	assert.Len(t, got, 1)
	assert.Equal(t, "KEDA001", got[0].RuleID)
	assert.Equal(t, 0, got[0].TriggerIndex)
	assert.Equal(t, "cpu", got[0].TriggerType)
	assert.Equal(t, "metadata.type", got[0].Field)
	assert.Contains(t, got[0].Message, "deprecated")
	assert.Contains(t, got[0].FixHint, "metricType: Utilization")
}

func TestKEDA001_MemoryWithMetadataType_FlagsViolation(t *testing.T) {
	r := &CpuMemoryMetadataType{}
	target := Target{
		Triggers: []kedav1alpha1.ScaleTriggers{
			{Type: "memory", Metadata: map[string]string{"type": "AverageValue", "value": "100Mi"}},
		},
	}

	got := r.Lint(target)

	assert.Len(t, got, 1)
	assert.Equal(t, "memory", got[0].TriggerType)
}

func TestKEDA001_CpuWithoutMetadataType_NoViolation(t *testing.T) {
	r := &CpuMemoryMetadataType{}
	target := Target{
		Triggers: []kedav1alpha1.ScaleTriggers{
			{Type: "cpu", MetricType: "Utilization", Metadata: map[string]string{"value": "50"}},
		},
	}

	got := r.Lint(target)
	assert.Empty(t, got)
}

func TestKEDA001_NonCpuMemoryTrigger_NoViolation(t *testing.T) {
	r := &CpuMemoryMetadataType{}
	target := Target{
		Triggers: []kedav1alpha1.ScaleTriggers{
			{Type: "prometheus", Metadata: map[string]string{"type": "anything"}},
		},
	}

	got := r.Lint(target)
	assert.Empty(t, got)
}

func TestKEDA001_MultiTrigger_ReportsCorrectIndex(t *testing.T) {
	r := &CpuMemoryMetadataType{}
	target := Target{
		Triggers: []kedav1alpha1.ScaleTriggers{
			{Type: "prometheus", Metadata: map[string]string{}},
			{Type: "cpu", Metadata: map[string]string{"type": "Utilization", "value": "50"}},
			{Type: "memory", Metadata: map[string]string{"type": "AverageValue", "value": "100Mi"}},
		},
	}

	got := r.Lint(target)
	assert.Len(t, got, 2)
	assert.Equal(t, 1, got[0].TriggerIndex)
	assert.Equal(t, 2, got[1].TriggerIndex)
}

func TestKEDA001_BothMetadataTypeAndMetricType_StillFlagsBecauseMetadataTypeIsRemovedIn218(t *testing.T) {
	r := &CpuMemoryMetadataType{}
	target := Target{
		Triggers: []kedav1alpha1.ScaleTriggers{
			{Type: "cpu", MetricType: "Utilization",
				Metadata: map[string]string{"type": "Utilization", "value": "50"}},
		},
	}
	got := r.Lint(target)
	assert.Len(t, got, 1)
}

func TestKEDA001_RegistryAutoRegistration(t *testing.T) {
	found := false
	for _, r := range Registry {
		if r.ID() == "KEDA001" {
			found = true
			assert.Equal(t, SeverityError, r.BuiltinDefaultSeverity())
		}
	}
	assert.True(t, found, "KEDA001 should be auto-registered via init()")
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `go test ./internal/rules/... -run TestKEDA001 -v`
Expected: FAIL — `CpuMemoryMetadataType` undefined.

- [ ] **Step 3: Implement keda001.go**

```go
// internal/rules/keda001.go
package rules

import "fmt"

type CpuMemoryMetadataType struct{}

func init() {
	Registry = append(Registry, &CpuMemoryMetadataType{})
}

func (*CpuMemoryMetadataType) ID() string                       { return "KEDA001" }
func (*CpuMemoryMetadataType) BuiltinDefaultSeverity() Severity { return SeverityError }

func (*CpuMemoryMetadataType) Lint(t Target) []Violation {
	var out []Violation
	for i, tr := range t.Triggers {
		if tr.Type != "cpu" && tr.Type != "memory" {
			continue
		}
		mdType, ok := tr.Metadata["type"]
		if !ok {
			continue
		}
		out = append(out, Violation{
			RuleID:       "KEDA001",
			TriggerIndex: i,
			TriggerType:  tr.Type,
			Field:        "metadata.type",
			Message: fmt.Sprintf(
				"trigger[%d] (type=%s): metadata.type is deprecated since KEDA 2.10 and removed in 2.18",
				i, tr.Type),
			FixHint: fmt.Sprintf(
				"Use triggers[%d].metricType: %s instead.", i, mdType),
		})
	}
	return out
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `go test ./internal/rules/... -v`
Expected: PASS — all 7 tests.

- [ ] **Step 5: Commit**

```bash
git add internal/rules/keda001.go internal/rules/keda001_test.go
git commit -m "feat(kdw): KEDA001 rule (cpu/memory metadata.type)"
```

---

### Task 4: Config schema and matcher

**Files:**
- Create: `internal/config/schema.go`
- Create: `internal/config/schema_test.go`

- [ ] **Step 1: Write the failing tests**

```go
// internal/config/schema_test.go
package config

import (
	"testing"

	"github.com/stretchr/testify/assert"
)

func TestNamespaceOverride_NamesGlob_ExactMatch(t *testing.T) {
	o := NamespaceOverride{Names: []string{"sandbox"}, Severity: "warn"}
	assert.True(t, o.matches("sandbox", nil))
	assert.False(t, o.matches("sandboxes", nil))
}

func TestNamespaceOverride_NamesGlob_StarMatch(t *testing.T) {
	o := NamespaceOverride{Names: []string{"experiment-*"}, Severity: "warn"}
	assert.True(t, o.matches("experiment-1", nil))
	assert.True(t, o.matches("experiment-foo-bar", nil))
	assert.False(t, o.matches("prod", nil))
}

func TestNamespaceOverride_LabelSelector_MatchLabels(t *testing.T) {
	o := NamespaceOverride{
		LabelSelector: &LabelSelector{MatchLabels: map[string]string{"tier": "legacy"}},
		Severity:      "warn",
	}
	assert.True(t, o.matches("any", map[string]string{"tier": "legacy"}))
	assert.False(t, o.matches("any", map[string]string{"tier": "prod"}))
	assert.False(t, o.matches("any", nil))
}

func TestNamespaceOverride_BothNamesAndSelector_ValidationFails(t *testing.T) {
	o := NamespaceOverride{
		Names:         []string{"x"},
		LabelSelector: &LabelSelector{MatchLabels: map[string]string{"a": "b"}},
	}
	assert.Error(t, o.Validate())
}

func TestNamespaceOverride_Neither_ValidationFails(t *testing.T) {
	o := NamespaceOverride{Severity: "warn"}
	assert.Error(t, o.Validate())
}

func TestNamespaceOverride_BadSeverity_ValidationFails(t *testing.T) {
	o := NamespaceOverride{Names: []string{"x"}, Severity: "bogus"}
	assert.Error(t, o.Validate())
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `go test ./internal/config/... -v`
Expected: FAIL — types undefined.

- [ ] **Step 3: Implement schema.go**

```go
// internal/config/schema.go
package config

import (
	"fmt"
	"path/filepath"

	"github.com/wys1203/keda-labs/internal/rules"
)

// Config is the parsed shape of the ConfigMap's `config.yaml` key.
type Config struct {
	Rules []RuleConfig `yaml:"rules" json:"rules"`
}

type RuleConfig struct {
	ID                 string              `yaml:"id"`
	DefaultSeverity    rules.Severity      `yaml:"defaultSeverity"`
	NamespaceOverrides []NamespaceOverride `yaml:"namespaceOverrides,omitempty"`
}

// NamespaceOverride matches a namespace by exact-or-glob name OR by label
// selector. Exactly one of `Names` or `LabelSelector` must be set.
type NamespaceOverride struct {
	Names         []string       `yaml:"names,omitempty"`
	LabelSelector *LabelSelector `yaml:"labelSelector,omitempty"`
	Severity      rules.Severity `yaml:"severity"`
}

type LabelSelector struct {
	MatchLabels      map[string]string  `yaml:"matchLabels,omitempty"`
	MatchExpressions []LabelRequirement `yaml:"matchExpressions,omitempty"`
}

type LabelRequirement struct {
	Key      string   `yaml:"key"`
	Operator string   `yaml:"operator"` // "In" | "NotIn" | "Exists" | "DoesNotExist"
	Values   []string `yaml:"values,omitempty"`
}

func (o *NamespaceOverride) Validate() error {
	switch {
	case len(o.Names) > 0 && o.LabelSelector != nil:
		return fmt.Errorf("namespaceOverrides entry must have exactly one of `names` or `labelSelector`, not both")
	case len(o.Names) == 0 && o.LabelSelector == nil:
		return fmt.Errorf("namespaceOverrides entry must have one of `names` or `labelSelector`")
	}
	if !validSeverity(o.Severity) {
		return fmt.Errorf("invalid severity %q (want error|warn|off)", o.Severity)
	}
	if o.LabelSelector != nil {
		for _, e := range o.LabelSelector.MatchExpressions {
			switch e.Operator {
			case "In", "NotIn", "Exists", "DoesNotExist":
			default:
				return fmt.Errorf("invalid matchExpressions operator %q", e.Operator)
			}
		}
	}
	return nil
}

func validSeverity(s rules.Severity) bool {
	switch s {
	case rules.SeverityError, rules.SeverityWarn, rules.SeverityOff:
		return true
	}
	return false
}

func (o *NamespaceOverride) matches(ns string, nsLabels map[string]string) bool {
	if len(o.Names) > 0 {
		for _, pat := range o.Names {
			if ok, _ := filepath.Match(pat, ns); ok {
				return true
			}
		}
		return false
	}
	if o.LabelSelector != nil {
		return labelSelectorMatches(o.LabelSelector, nsLabels)
	}
	return false
}

func labelSelectorMatches(sel *LabelSelector, labels map[string]string) bool {
	for k, v := range sel.MatchLabels {
		if labels[k] != v {
			return false
		}
	}
	for _, e := range sel.MatchExpressions {
		val, present := labels[e.Key]
		switch e.Operator {
		case "Exists":
			if !present {
				return false
			}
		case "DoesNotExist":
			if present {
				return false
			}
		case "In":
			if !present || !contains(e.Values, val) {
				return false
			}
		case "NotIn":
			if present && contains(e.Values, val) {
				return false
			}
		}
	}
	return true
}

func contains(haystack []string, needle string) bool {
	for _, h := range haystack {
		if h == needle {
			return true
		}
	}
	return false
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `go test ./internal/config/... -v`
Expected: PASS — 6 tests.

- [ ] **Step 5: Commit**

```bash
git add internal/config/schema.go internal/config/schema_test.go
git commit -m "feat(kdw): config schema with namespace override matcher"
```

---

### Task 5: Severity resolver

**Files:**
- Create: `internal/config/resolver.go`
- Create: `internal/config/resolver_test.go`

- [ ] **Step 1: Write the failing tests**

```go
// internal/config/resolver_test.go
package config

import (
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/wys1203/keda-labs/internal/rules"
)

func TestEffectiveSeverity_NoMatch_FallsBackToDefault(t *testing.T) {
	c := &Config{Rules: []RuleConfig{{
		ID: "KEDA001", DefaultSeverity: rules.SeverityError,
		NamespaceOverrides: []NamespaceOverride{
			{Names: []string{"sandbox"}, Severity: rules.SeverityWarn},
		},
	}}}
	assert.Equal(t, rules.SeverityError, c.EffectiveSeverity("KEDA001", "prod", nil))
}

func TestEffectiveSeverity_NameOverride_Wins(t *testing.T) {
	c := &Config{Rules: []RuleConfig{{
		ID: "KEDA001", DefaultSeverity: rules.SeverityError,
		NamespaceOverrides: []NamespaceOverride{
			{Names: []string{"sandbox"}, Severity: rules.SeverityWarn},
		},
	}}}
	assert.Equal(t, rules.SeverityWarn, c.EffectiveSeverity("KEDA001", "sandbox", nil))
}

func TestEffectiveSeverity_LabelOverride_Wins(t *testing.T) {
	c := &Config{Rules: []RuleConfig{{
		ID: "KEDA001", DefaultSeverity: rules.SeverityError,
		NamespaceOverrides: []NamespaceOverride{
			{LabelSelector: &LabelSelector{MatchLabels: map[string]string{"tier": "legacy"}}, Severity: rules.SeverityOff},
		},
	}}}
	assert.Equal(t, rules.SeverityOff, c.EffectiveSeverity("KEDA001", "anything", map[string]string{"tier": "legacy"}))
}

func TestEffectiveSeverity_FirstMatchWins(t *testing.T) {
	c := &Config{Rules: []RuleConfig{{
		ID: "KEDA001", DefaultSeverity: rules.SeverityError,
		NamespaceOverrides: []NamespaceOverride{
			{Names: []string{"x"}, Severity: rules.SeverityOff},
			{Names: []string{"x"}, Severity: rules.SeverityWarn},
		},
	}}}
	assert.Equal(t, rules.SeverityOff, c.EffectiveSeverity("KEDA001", "x", nil))
}

func TestEffectiveSeverity_UnknownRule_UsesBuiltinDefault(t *testing.T) {
	c := &Config{Rules: nil} // CM has no entry for KEDA001
	assert.Equal(t, rules.SeverityError, c.EffectiveSeverity("KEDA001", "x", nil))
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `go test ./internal/config/... -run TestEffectiveSeverity -v`
Expected: FAIL — `EffectiveSeverity` undefined.

- [ ] **Step 3: Implement resolver.go**

```go
// internal/config/resolver.go
package config

import "github.com/wys1203/keda-labs/internal/rules"

// EffectiveSeverity is called by both webhook handler and controller for
// every (ruleID, namespace) pair. Behaviour MUST stay identical between
// the two call sites — that's the whole point of having one function.
func (c *Config) EffectiveSeverity(ruleID, ns string, nsLabels map[string]string) rules.Severity {
	if rc, ok := c.findRule(ruleID); ok {
		for _, o := range rc.NamespaceOverrides {
			if o.matches(ns, nsLabels) {
				return o.Severity
			}
		}
		return rc.DefaultSeverity
	}
	return c.builtinDefault(ruleID)
}

func (c *Config) findRule(id string) (*RuleConfig, bool) {
	for i := range c.Rules {
		if c.Rules[i].ID == id {
			return &c.Rules[i], true
		}
	}
	return nil, false
}

func (c *Config) builtinDefault(id string) rules.Severity {
	for _, r := range rules.Registry {
		if r.ID() == id {
			return r.BuiltinDefaultSeverity()
		}
	}
	return rules.SeverityOff // unknown rule: be quiet
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `go test ./internal/config/... -v`
Expected: PASS — all tests.

- [ ] **Step 5: Commit**

```bash
git add internal/config/resolver.go internal/config/resolver_test.go
git commit -m "feat(kdw): severity resolver with first-match-wins overrides"
```

---

### Task 6: Config loader (strict YAML + validation)

**Files:**
- Create: `internal/config/loader.go`
- Create: `internal/config/loader_test.go`

- [ ] **Step 1: Write the failing tests**

```go
// internal/config/loader_test.go
package config

import (
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
	"github.com/wys1203/keda-labs/internal/rules"
)

func TestParseYAML_ValidConfig(t *testing.T) {
	data := []byte(`
rules:
  - id: KEDA001
    defaultSeverity: error
    namespaceOverrides:
      - names: ["sandbox", "experiment-*"]
        severity: warn
      - labelSelector:
          matchLabels:
            tier: legacy
        severity: off
`)
	cfg, err := ParseYAML(data)
	require.NoError(t, err)
	require.Len(t, cfg.Rules, 1)
	assert.Equal(t, "KEDA001", cfg.Rules[0].ID)
	assert.Equal(t, rules.SeverityError, cfg.Rules[0].DefaultSeverity)
	assert.Len(t, cfg.Rules[0].NamespaceOverrides, 2)
}

func TestParseYAML_RejectsUnknownField(t *testing.T) {
	data := []byte(`
rules:
  - id: KEDA001
    defaultSeverity: error
    bogusField: 1
`)
	_, err := ParseYAML(data)
	assert.Error(t, err)
}

func TestParseYAML_RejectsBadOverride(t *testing.T) {
	data := []byte(`
rules:
  - id: KEDA001
    defaultSeverity: error
    namespaceOverrides:
      - severity: warn   # neither names nor labelSelector
`)
	_, err := ParseYAML(data)
	assert.Error(t, err)
}

func TestParseYAML_RejectsBadSeverity(t *testing.T) {
	data := []byte(`
rules:
  - id: KEDA001
    defaultSeverity: panic
`)
	_, err := ParseYAML(data)
	assert.Error(t, err)
}

func TestParseYAML_UnknownRuleID_LoadsButLogged(t *testing.T) {
	// per spec: unknown rule IDs are logged and skipped at use time, not at parse.
	data := []byte(`
rules:
  - id: KEDA999
    defaultSeverity: error
`)
	cfg, err := ParseYAML(data)
	require.NoError(t, err)
	assert.Len(t, cfg.Rules, 1)
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `go test ./internal/config/... -run TestParseYAML -v`
Expected: FAIL — `ParseYAML` undefined.

- [ ] **Step 3: Implement loader.go**

```go
// internal/config/loader.go
package config

import (
	"fmt"

	"sigs.k8s.io/yaml"
)

// ParseYAML strictly unmarshals data into Config. Unknown fields are an
// error so typos in operator-managed CMs can't silently widen behaviour.
func ParseYAML(data []byte) (*Config, error) {
	var raw Config
	if err := yaml.UnmarshalStrict(data, &raw); err != nil {
		return nil, fmt.Errorf("parse yaml: %w", err)
	}
	if err := raw.Validate(); err != nil {
		return nil, err
	}
	return &raw, nil
}

func (c *Config) Validate() error {
	for i, r := range c.Rules {
		if r.ID == "" {
			return fmt.Errorf("rules[%d]: id is required", i)
		}
		if !validSeverity(r.DefaultSeverity) {
			return fmt.Errorf("rules[%d]: invalid defaultSeverity %q", i, r.DefaultSeverity)
		}
		for j, o := range r.NamespaceOverrides {
			if err := o.Validate(); err != nil {
				return fmt.Errorf("rules[%d].namespaceOverrides[%d]: %w", i, j, err)
			}
		}
	}
	return nil
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `go test ./internal/config/... -v`
Expected: PASS — all loader + earlier tests.

- [ ] **Step 5: Commit**

```bash
git add internal/config/loader.go internal/config/loader_test.go
git commit -m "feat(kdw): strict YAML config loader"
```

---

### Task 7: Config store (atomic.Value + generation counter)

**Files:**
- Create: `internal/config/store.go`
- Create: `internal/config/store_test.go`

- [ ] **Step 1: Write the failing tests**

```go
// internal/config/store_test.go
package config

import (
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/wys1203/keda-labs/internal/rules"
)

func TestStore_DefaultLoad_ReturnsEmptyConfig(t *testing.T) {
	s := NewStore()
	cfg := s.Load()
	assert.NotNil(t, cfg)
	assert.Empty(t, cfg.Rules)
	assert.Equal(t, uint64(0), s.Generation())
}

func TestStore_StoreThenLoad_RoundTripsAndBumpsGeneration(t *testing.T) {
	s := NewStore()
	c := &Config{Rules: []RuleConfig{{ID: "KEDA001", DefaultSeverity: rules.SeverityError}}}
	s.Store(c)
	got := s.Load()
	assert.Equal(t, "KEDA001", got.Rules[0].ID)
	assert.Equal(t, uint64(1), s.Generation())
	s.Store(c)
	assert.Equal(t, uint64(2), s.Generation())
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `go test ./internal/config/... -run TestStore -v`
Expected: FAIL — `NewStore`/`Store` undefined.

- [ ] **Step 3: Implement store.go**

```go
// internal/config/store.go
package config

import (
	"sync/atomic"
)

// Store holds the live Config in an atomic.Value so the webhook handler's
// hot path can do a lock-free Load() per admission request.
type Store struct {
	v   atomic.Pointer[Config]
	gen atomic.Uint64
}

func NewStore() *Store {
	s := &Store{}
	s.v.Store(&Config{}) // never return nil to callers
	return s
}

func (s *Store) Load() *Config {
	return s.v.Load()
}

func (s *Store) Store(c *Config) {
	s.v.Store(c)
	s.gen.Add(1)
}

func (s *Store) Generation() uint64 {
	return s.gen.Load()
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `go test ./internal/config/... -v`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add internal/config/store.go internal/config/store_test.go
git commit -m "feat(kdw): atomic config store with generation counter"
```

---

### Task 8: Metrics collectors

**Files:**
- Create: `internal/metrics/metrics.go`
- Create: `internal/metrics/metrics_test.go`

- [ ] **Step 1: Write the failing tests**

```go
// internal/metrics/metrics_test.go
package metrics

import (
	"strings"
	"testing"

	"github.com/prometheus/client_golang/prometheus/testutil"
	"github.com/stretchr/testify/assert"
)

func TestNew_RegistersAllCollectors(t *testing.T) {
	m := New()
	// Ensure every exposed collector returns a non-nil reference.
	assert.NotNil(t, m.Violations)
	assert.NotNil(t, m.AdmissionRejects)
	assert.NotNil(t, m.AdmissionWarnings)
	assert.NotNil(t, m.ConfigReloads)
	assert.NotNil(t, m.ConfigGeneration)
}

func TestViolations_GaugeIncrementsOnSetAndClearsOnDelete(t *testing.T) {
	m := New()
	labels := ViolationLabels{
		Namespace: "demo", Kind: "ScaledObject", Name: "x",
		TriggerIndex: "0", TriggerType: "cpu", RuleID: "KEDA001", Severity: "error",
	}
	m.Violations.With(labels.toMap()).Set(1)
	assert.Equal(t, float64(1), testutil.ToFloat64(m.Violations.With(labels.toMap())))
	m.Violations.Delete(labels.toMap())
	// re-fetching after Delete creates a fresh series at 0.
	assert.Equal(t, float64(0), testutil.ToFloat64(m.Violations.With(labels.toMap())))
}

func TestRejectsAndWarnings_Counters(t *testing.T) {
	m := New()
	m.AdmissionRejects.WithLabelValues("demo", "ScaledObject", "KEDA001", "CREATE").Inc()
	m.AdmissionWarnings.WithLabelValues("demo", "ScaledObject", "KEDA001").Inc()
	assert.Equal(t, float64(1), testutil.ToFloat64(m.AdmissionRejects.WithLabelValues("demo", "ScaledObject", "KEDA001", "CREATE")))
	assert.Equal(t, float64(1), testutil.ToFloat64(m.AdmissionWarnings.WithLabelValues("demo", "ScaledObject", "KEDA001")))
}

func TestConfigReloads_LabelsAndGeneration(t *testing.T) {
	m := New()
	m.ConfigReloads.WithLabelValues("success").Inc()
	m.ConfigReloads.WithLabelValues("error").Inc()
	m.ConfigGeneration.Set(7)
	assert.Equal(t, float64(1), testutil.ToFloat64(m.ConfigReloads.WithLabelValues("success")))
	assert.Equal(t, float64(1), testutil.ToFloat64(m.ConfigReloads.WithLabelValues("error")))
	assert.Equal(t, float64(7), testutil.ToFloat64(m.ConfigGeneration))
}

func TestMetricNames_MatchSpec(t *testing.T) {
	expected := []string{
		"keda_deprecation_violations",
		"keda_deprecation_admission_rejects_total",
		"keda_deprecation_admission_warnings_total",
		"keda_deprecation_config_reloads_total",
		"keda_deprecation_config_generation",
	}
	dump := dumpMetricNames(t, New())
	for _, name := range expected {
		assert.True(t, strings.Contains(dump, name), "missing metric %q in registry", name)
	}
}
```

Plus a small test helper in the same file:

```go
func dumpMetricNames(t *testing.T, m *Metrics) string {
	t.Helper()
	// Force one labelled sample per collector so they appear in the output.
	m.Violations.With(map[string]string{
		"namespace": "n", "kind": "k", "name": "x",
		"trigger_index": "0", "trigger_type": "cpu", "rule_id": "K", "severity": "warn",
	}).Set(1)
	m.AdmissionRejects.WithLabelValues("n", "k", "K", "CREATE").Inc()
	m.AdmissionWarnings.WithLabelValues("n", "k", "K").Inc()
	m.ConfigReloads.WithLabelValues("success").Inc()
	m.ConfigGeneration.Set(1)

	var sb strings.Builder
	mfs, err := m.Registry.Gather()
	if err != nil {
		t.Fatalf("gather: %v", err)
	}
	for _, mf := range mfs {
		sb.WriteString(mf.GetName())
		sb.WriteString("\n")
	}
	return sb.String()
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `go test ./internal/metrics/... -v`
Expected: FAIL — package undefined.

- [ ] **Step 3: Implement metrics.go**

```go
// internal/metrics/metrics.go
package metrics

import (
	"github.com/prometheus/client_golang/prometheus"
)

// Metrics owns its own Prometheus Registry so tests are isolated. main()
// wires the registry into the metrics HTTP handler.
type Metrics struct {
	Registry *prometheus.Registry

	// Gauge: one series per current violation. Re-emitted on every reconcile.
	Violations *prometheus.GaugeVec

	// Counters: emitted from the webhook hot path.
	AdmissionRejects  *prometheus.CounterVec
	AdmissionWarnings *prometheus.CounterVec

	// Config reload health.
	ConfigReloads    *prometheus.CounterVec // labels: result=success|error
	ConfigGeneration prometheus.Gauge       // monotonic, bumped per successful reload
}

const (
	subsystem = "keda_deprecation"
)

// ViolationLabels mirrors the gauge's label schema. Use toMap() to feed
// it to Prometheus and to Emitter's bookkeeping.
type ViolationLabels struct {
	Namespace    string
	Kind         string
	Name         string
	TriggerIndex string
	TriggerType  string
	RuleID       string
	Severity     string
}

func (v ViolationLabels) toMap() prometheus.Labels {
	return prometheus.Labels{
		"namespace":     v.Namespace,
		"kind":          v.Kind,
		"name":          v.Name,
		"trigger_index": v.TriggerIndex,
		"trigger_type":  v.TriggerType,
		"rule_id":       v.RuleID,
		"severity":      v.Severity,
	}
}

func (v ViolationLabels) ToMap() prometheus.Labels { return v.toMap() }

func New() *Metrics {
	r := prometheus.NewRegistry()
	m := &Metrics{
		Registry: r,
		Violations: prometheus.NewGaugeVec(
			prometheus.GaugeOpts{Name: "keda_deprecation_violations",
				Help: "1 per active KEDA deprecation violation."},
			[]string{"namespace", "kind", "name", "trigger_index", "trigger_type", "rule_id", "severity"},
		),
		AdmissionRejects: prometheus.NewCounterVec(
			prometheus.CounterOpts{Name: "keda_deprecation_admission_rejects_total",
				Help: "Total ScaledObject/ScaledJob admission rejections by KDW."},
			[]string{"namespace", "kind", "rule_id", "operation"},
		),
		AdmissionWarnings: prometheus.NewCounterVec(
			prometheus.CounterOpts{Name: "keda_deprecation_admission_warnings_total",
				Help: "Total admission warnings emitted by KDW."},
			[]string{"namespace", "kind", "rule_id"},
		),
		ConfigReloads: prometheus.NewCounterVec(
			prometheus.CounterOpts{Name: "keda_deprecation_config_reloads_total",
				Help: "Config reload attempts by result."},
			[]string{"result"},
		),
		ConfigGeneration: prometheus.NewGauge(
			prometheus.GaugeOpts{Name: "keda_deprecation_config_generation",
				Help: "Monotonic generation of the live config; bumped per successful reload."},
		),
	}
	r.MustRegister(m.Violations, m.AdmissionRejects, m.AdmissionWarnings, m.ConfigReloads, m.ConfigGeneration)
	return m
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `go test ./internal/metrics/... -v`
Expected: PASS — all tests.

- [ ] **Step 5: Commit**

```bash
git add internal/metrics/metrics.go internal/metrics/metrics_test.go
git commit -m "feat(kdw): Prometheus metrics collectors"
```

---

### Task 9: Webhook diff (additive-only key)

**Files:**
- Create: `internal/webhook/diff.go`
- Create: `internal/webhook/diff_test.go`

- [ ] **Step 1: Write the failing tests**

```go
// internal/webhook/diff_test.go
package webhook

import (
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/wys1203/keda-labs/internal/rules"
)

func TestDiffByKey_NewViolation_IsAdded(t *testing.T) {
	old := []rules.Violation{}
	new := []rules.Violation{
		{RuleID: "KEDA001", TriggerType: "cpu", Field: "metadata.type"},
	}
	got := DiffByKey(new, old)
	assert.Len(t, got, 1)
}

func TestDiffByKey_SameViolationOnUpdate_NotAdded(t *testing.T) {
	v := rules.Violation{RuleID: "KEDA001", TriggerType: "cpu", Field: "metadata.type"}
	got := DiffByKey([]rules.Violation{v}, []rules.Violation{v})
	assert.Empty(t, got)
}

// This is the case our spec change pinned: pure trigger-reorder must NOT
// look like a new violation.
func TestDiffByKey_TriggerReorder_NotAdded(t *testing.T) {
	oldV := []rules.Violation{
		{RuleID: "KEDA001", TriggerIndex: 0, TriggerType: "cpu", Field: "metadata.type"},
		{RuleID: "KEDA001", TriggerIndex: 1, TriggerType: "memory", Field: "metadata.type"},
	}
	newV := []rules.Violation{
		{RuleID: "KEDA001", TriggerIndex: 0, TriggerType: "memory", Field: "metadata.type"},
		{RuleID: "KEDA001", TriggerIndex: 1, TriggerType: "cpu", Field: "metadata.type"},
	}
	got := DiffByKey(newV, oldV)
	assert.Empty(t, got)
}

func TestDiffByKey_ChangingTriggerTypeOnSameIndex_IsAdded(t *testing.T) {
	// User had 1 prometheus trigger, now adds metadata.type to a new memory
	// trigger at the same index. The TriggerType on the violation is
	// "memory" which didn't exist before → counted as added.
	oldV := []rules.Violation{}
	newV := []rules.Violation{
		{RuleID: "KEDA001", TriggerIndex: 0, TriggerType: "memory", Field: "metadata.type"},
	}
	got := DiffByKey(newV, oldV)
	assert.Len(t, got, 1)
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `go test ./internal/webhook/... -run TestDiffByKey -v`
Expected: FAIL — `DiffByKey` undefined.

- [ ] **Step 3: Implement diff.go**

```go
// internal/webhook/diff.go
package webhook

import "github.com/wys1203/keda-labs/internal/rules"

// DiffByKey returns violations present in `new` whose key
// (RuleID, TriggerType, Field) is not present in `old`.
//
// TriggerIndex is intentionally NOT part of the key so that pure trigger
// reordering on UPDATE is not mis-classified as added violations.
//
// TriggerType IS part of the key so that swapping cpu→memory on the same
// trigger (still using metadata.type) is treated as a *new* memory-flavoured
// violation that didn't exist before — which is the desired strictness.
func DiffByKey(new, old []rules.Violation) []rules.Violation {
	type key struct{ RuleID, TriggerType, Field string }
	have := make(map[key]struct{}, len(old))
	for _, v := range old {
		have[key{v.RuleID, v.TriggerType, v.Field}] = struct{}{}
	}
	var added []rules.Violation
	for _, v := range new {
		if _, ok := have[key{v.RuleID, v.TriggerType, v.Field}]; !ok {
			added = append(added, v)
		}
	}
	return added
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `go test ./internal/webhook/... -v`
Expected: PASS — 4 tests.

- [ ] **Step 5: Commit**

```bash
git add internal/webhook/diff.go internal/webhook/diff_test.go
git commit -m "feat(kdw): additive-only diff keyed by (RuleID, TriggerType, Field)"
```

---

### Task 10: Webhook handler (admission decision)

**Files:**
- Create: `internal/webhook/handler.go`
- Create: `internal/webhook/handler_test.go`

- [ ] **Step 1: Write the failing tests**

```go
// internal/webhook/handler_test.go
package webhook

import (
	"context"
	"encoding/json"
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
	admissionv1 "k8s.io/api/admission/v1"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/runtime"
	kedav1alpha1 "github.com/kedacore/keda/v2/apis/keda/v1alpha1"
	"sigs.k8s.io/controller-runtime/pkg/webhook/admission"

	"github.com/wys1203/keda-labs/internal/config"
	"github.com/wys1203/keda-labs/internal/metrics"
	"github.com/wys1203/keda-labs/internal/rules"
)

type fakeNSCache struct{ labels map[string]map[string]string }

func (f *fakeNSCache) Get(ns string) map[string]string { return f.labels[ns] }

func mustEncode(t *testing.T, obj runtime.Object) runtime.RawExtension {
	t.Helper()
	b, err := json.Marshal(obj)
	require.NoError(t, err)
	return runtime.RawExtension{Raw: b}
}

func soWithDeprecatedCpu(name, ns string) *kedav1alpha1.ScaledObject {
	return &kedav1alpha1.ScaledObject{
		TypeMeta:   metav1.TypeMeta{APIVersion: "keda.sh/v1alpha1", Kind: "ScaledObject"},
		ObjectMeta: metav1.ObjectMeta{Name: name, Namespace: ns},
		Spec: kedav1alpha1.ScaledObjectSpec{
			ScaleTargetRef: &kedav1alpha1.ScaleTarget{Name: name},
			Triggers: []kedav1alpha1.ScaleTriggers{
				{Type: "cpu", Metadata: map[string]string{"type": "Utilization", "value": "50"}},
			},
		},
	}
}

func soClean(name, ns string) *kedav1alpha1.ScaledObject {
	so := soWithDeprecatedCpu(name, ns)
	so.Spec.Triggers = []kedav1alpha1.ScaleTriggers{
		{Type: "cpu", MetricType: "Utilization", Metadata: map[string]string{"value": "50"}},
	}
	return so
}

func newHandler(t *testing.T, cfg *config.Config) *Handler {
	t.Helper()
	store := config.NewStore()
	store.Store(cfg)
	return &Handler{
		Config:   store,
		NSCache:  &fakeNSCache{},
		Metrics:  metrics.New(),
		MsgURL:   "https://wiki.example/migrations/keda-2.18",
	}
}

func TestHandle_Create_DeprecatedSpec_InErrorNs_Rejects(t *testing.T) {
	h := newHandler(t, &config.Config{Rules: []config.RuleConfig{
		{ID: "KEDA001", DefaultSeverity: rules.SeverityError},
	}})
	req := admission.Request{AdmissionRequest: admissionv1.AdmissionRequest{
		Operation: admissionv1.Create,
		Namespace: "demo",
		Kind:      metav1.GroupVersionKind{Group: "keda.sh", Version: "v1alpha1", Kind: "ScaledObject"},
		Object:    mustEncode(t, soWithDeprecatedCpu("x", "demo")),
	}}
	resp := h.Handle(context.Background(), req)
	assert.False(t, resp.Allowed)
	assert.Contains(t, resp.Result.Message, "KEDA001")
	assert.Contains(t, resp.Result.Message, "metricType: Utilization")
}

func TestHandle_Create_CleanSpec_Allows(t *testing.T) {
	h := newHandler(t, &config.Config{Rules: []config.RuleConfig{
		{ID: "KEDA001", DefaultSeverity: rules.SeverityError},
	}})
	req := admission.Request{AdmissionRequest: admissionv1.AdmissionRequest{
		Operation: admissionv1.Create,
		Namespace: "demo",
		Kind:      metav1.GroupVersionKind{Group: "keda.sh", Version: "v1alpha1", Kind: "ScaledObject"},
		Object:    mustEncode(t, soClean("x", "demo")),
	}}
	resp := h.Handle(context.Background(), req)
	assert.True(t, resp.Allowed)
	assert.Empty(t, resp.Warnings)
}

func TestHandle_Create_DeprecatedSpec_InWarnNs_AllowsWithWarning(t *testing.T) {
	h := newHandler(t, &config.Config{Rules: []config.RuleConfig{
		{ID: "KEDA001", DefaultSeverity: rules.SeverityError,
			NamespaceOverrides: []config.NamespaceOverride{
				{Names: []string{"demo"}, Severity: rules.SeverityWarn},
			}},
	}})
	req := admission.Request{AdmissionRequest: admissionv1.AdmissionRequest{
		Operation: admissionv1.Create,
		Namespace: "demo",
		Kind:      metav1.GroupVersionKind{Group: "keda.sh", Version: "v1alpha1", Kind: "ScaledObject"},
		Object:    mustEncode(t, soWithDeprecatedCpu("x", "demo")),
	}}
	resp := h.Handle(context.Background(), req)
	assert.True(t, resp.Allowed)
	require.NotEmpty(t, resp.Warnings)
	assert.Contains(t, resp.Warnings[0], "KEDA001")
}

func TestHandle_Update_NoNewViolation_AllowsWithWarning(t *testing.T) {
	h := newHandler(t, &config.Config{Rules: []config.RuleConfig{
		{ID: "KEDA001", DefaultSeverity: rules.SeverityError},
	}})
	old := soWithDeprecatedCpu("x", "demo")
	new := soWithDeprecatedCpu("x", "demo")
	new.Spec.MaxReplicaCount = ptrInt32(8) // unrelated change
	req := admission.Request{AdmissionRequest: admissionv1.AdmissionRequest{
		Operation: admissionv1.Update,
		Namespace: "demo",
		Kind:      metav1.GroupVersionKind{Group: "keda.sh", Version: "v1alpha1", Kind: "ScaledObject"},
		Object:    mustEncode(t, new),
		OldObject: mustEncode(t, old),
	}}
	resp := h.Handle(context.Background(), req)
	assert.True(t, resp.Allowed, "additive-only: no new error violation, should pass")
	require.NotEmpty(t, resp.Warnings)
}

func TestHandle_Update_AddsViolation_Rejects(t *testing.T) {
	h := newHandler(t, &config.Config{Rules: []config.RuleConfig{
		{ID: "KEDA001", DefaultSeverity: rules.SeverityError},
	}})
	old := soClean("x", "demo")
	new := soWithDeprecatedCpu("x", "demo")
	req := admission.Request{AdmissionRequest: admissionv1.AdmissionRequest{
		Operation: admissionv1.Update,
		Namespace: "demo",
		Kind:      metav1.GroupVersionKind{Group: "keda.sh", Version: "v1alpha1", Kind: "ScaledObject"},
		Object:    mustEncode(t, new),
		OldObject: mustEncode(t, old),
	}}
	resp := h.Handle(context.Background(), req)
	assert.False(t, resp.Allowed)
}

func ptrInt32(v int32) *int32 { return &v }
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `go test ./internal/webhook/... -run TestHandle -v`
Expected: FAIL — `Handler` undefined.

- [ ] **Step 3: Implement handler.go**

```go
// internal/webhook/handler.go
package webhook

import (
	"context"
	"encoding/json"
	"fmt"
	"strings"

	admissionv1 "k8s.io/api/admission/v1"
	"sigs.k8s.io/controller-runtime/pkg/webhook/admission"

	kedav1alpha1 "github.com/kedacore/keda/v2/apis/keda/v1alpha1"

	"github.com/wys1203/keda-labs/internal/config"
	"github.com/wys1203/keda-labs/internal/metrics"
	"github.com/wys1203/keda-labs/internal/rules"
)

type NamespaceCache interface {
	Get(ns string) map[string]string
}

type Handler struct {
	Config  *config.Store
	NSCache NamespaceCache
	Metrics *metrics.Metrics
	MsgURL  string // optional internal runbook URL surfaced in rejection messages
}

func (h *Handler) Handle(_ context.Context, req admission.Request) admission.Response {
	cfg := h.Config.Load()
	nsLabels := h.NSCache.Get(req.Namespace)

	newT, err := decodeTarget(req.Object.Raw, req.Kind.Kind, req.Namespace)
	if err != nil {
		return admission.Errored(400, fmt.Errorf("decode new object: %w", err))
	}

	var oldT *rules.Target
	if req.Operation == admissionv1.Update && len(req.OldObject.Raw) > 0 {
		o, err := decodeTarget(req.OldObject.Raw, req.Kind.Kind, req.Namespace)
		if err != nil {
			return admission.Errored(400, fmt.Errorf("decode old object: %w", err))
		}
		oldT = &o
	}

	newV := rules.LintAll(newT)
	var oldV []rules.Violation
	if oldT != nil {
		oldV = rules.LintAll(*oldT)
	}

	candidates := newV
	if oldT != nil {
		candidates = DiffByKey(newV, oldV)
	}

	var rejecting []rules.Violation
	for _, v := range candidates {
		if cfg.EffectiveSeverity(v.RuleID, req.Namespace, nsLabels) == rules.SeverityError {
			rejecting = append(rejecting, v)
		}
	}
	if len(rejecting) > 0 {
		op := string(req.Operation)
		for _, v := range rejecting {
			h.Metrics.AdmissionRejects.WithLabelValues(req.Namespace, req.Kind.Kind, v.RuleID, op).Inc()
		}
		return admission.Denied(formatRejection(rejecting, h.MsgURL))
	}

	var warnings []string
	for _, v := range newV {
		sev := cfg.EffectiveSeverity(v.RuleID, req.Namespace, nsLabels)
		if sev == rules.SeverityOff {
			continue
		}
		warnings = append(warnings, formatWarning(v))
		h.Metrics.AdmissionWarnings.WithLabelValues(req.Namespace, req.Kind.Kind, v.RuleID).Inc()
	}
	resp := admission.Allowed("")
	resp.Warnings = warnings
	return resp
}

func decodeTarget(raw []byte, kind, ns string) (rules.Target, error) {
	switch kind {
	case "ScaledObject":
		var obj kedav1alpha1.ScaledObject
		if err := json.Unmarshal(raw, &obj); err != nil {
			return rules.Target{}, err
		}
		return rules.Target{Kind: kind, Namespace: obj.Namespace, Name: obj.Name, Triggers: obj.Spec.Triggers}, nil
	case "ScaledJob":
		var obj kedav1alpha1.ScaledJob
		if err := json.Unmarshal(raw, &obj); err != nil {
			return rules.Target{}, err
		}
		return rules.Target{Kind: kind, Namespace: obj.Namespace, Name: obj.Name, Triggers: obj.Spec.Triggers}, nil
	default:
		return rules.Target{}, fmt.Errorf("unsupported kind %q", kind)
	}
}

func formatRejection(vs []rules.Violation, msgURL string) string {
	var sb strings.Builder
	sb.WriteString("rejected by keda-deprecation-webhook:\n")
	for _, v := range vs {
		fmt.Fprintf(&sb, "  - [%s] %s — %s\n", v.RuleID, v.Message, v.FixHint)
	}
	if msgURL != "" {
		fmt.Fprintf(&sb, "see %s for migration guidance.\n", msgURL)
	}
	return sb.String()
}

func formatWarning(v rules.Violation) string {
	return fmt.Sprintf("[%s] %s — %s", v.RuleID, v.Message, v.FixHint)
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `go test ./internal/webhook/... -v`
Expected: PASS — all handler + diff tests.

- [ ] **Step 5: Commit**

```bash
git add internal/webhook/handler.go internal/webhook/handler_test.go
git commit -m "feat(kdw): admission handler with additive-only enforcement"
```

---

### Task 11: Emitter (per-object lastLabels bookkeeping)

**Files:**
- Create: `internal/controller/emitter.go`
- Create: `internal/controller/emitter_test.go`

- [ ] **Step 1: Write the failing tests**

```go
// internal/controller/emitter_test.go
package controller

import (
	"testing"

	"github.com/prometheus/client_golang/prometheus/testutil"
	"github.com/stretchr/testify/assert"
	"k8s.io/apimachinery/pkg/types"

	"github.com/wys1203/keda-labs/internal/metrics"
)

func mkLabels(severity string) metrics.ViolationLabels {
	return metrics.ViolationLabels{
		Namespace: "demo", Kind: "ScaledObject", Name: "x",
		TriggerIndex: "0", TriggerType: "cpu", RuleID: "KEDA001", Severity: severity,
	}
}

func TestEmitter_Sync_SetsNewSeries(t *testing.T) {
	m := metrics.New()
	e := NewEmitter(m)
	key := types.NamespacedName{Namespace: "demo", Name: "x"}

	e.Sync(key, []metrics.ViolationLabels{mkLabels("error")})

	assert.Equal(t, float64(1), testutil.ToFloat64(m.Violations.With(mkLabels("error").ToMap())))
}

func TestEmitter_Sync_RemovesObsoleteSeries(t *testing.T) {
	m := metrics.New()
	e := NewEmitter(m)
	key := types.NamespacedName{Namespace: "demo", Name: "x"}

	e.Sync(key, []metrics.ViolationLabels{mkLabels("error")})
	// CM hot-reload flips severity error→warn; new label set replaces old.
	e.Sync(key, []metrics.ViolationLabels{mkLabels("warn")})

	assert.Equal(t, float64(0), testutil.ToFloat64(m.Violations.With(mkLabels("error").ToMap())),
		"old severity=error series must be deleted, not left as a ghost")
	assert.Equal(t, float64(1), testutil.ToFloat64(m.Violations.With(mkLabels("warn").ToMap())))
}

func TestEmitter_Forget_RemovesAllSeriesForObject(t *testing.T) {
	m := metrics.New()
	e := NewEmitter(m)
	key := types.NamespacedName{Namespace: "demo", Name: "x"}

	e.Sync(key, []metrics.ViolationLabels{mkLabels("error")})
	e.Forget(key)

	assert.Equal(t, float64(0), testutil.ToFloat64(m.Violations.With(mkLabels("error").ToMap())))
}

func TestEmitter_Sync_EmptyNew_DropsAllSeriesForObject(t *testing.T) {
	m := metrics.New()
	e := NewEmitter(m)
	key := types.NamespacedName{Namespace: "demo", Name: "x"}

	e.Sync(key, []metrics.ViolationLabels{mkLabels("error")})
	e.Sync(key, nil) // violation gone after migration

	assert.Equal(t, float64(0), testutil.ToFloat64(m.Violations.With(mkLabels("error").ToMap())))
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `go test ./internal/controller/... -run TestEmitter -v`
Expected: FAIL — `NewEmitter` undefined.

- [ ] **Step 3: Implement emitter.go**

```go
// internal/controller/emitter.go
package controller

import (
	"sync"

	"k8s.io/apimachinery/pkg/types"

	"github.com/wys1203/keda-labs/internal/metrics"
)

// Emitter holds the source-of-truth for which gauge series are currently
// asserted, keyed by the owning object. It diffs the previous label set
// against the new one on each Sync so that severity flips, namespace label
// changes, and trigger edits all leave a consistent gauge state — no ghost
// series under prior severity labels.
type Emitter struct {
	mu      sync.Mutex
	last    map[types.NamespacedName][]metrics.ViolationLabels
	metrics *metrics.Metrics
}

func NewEmitter(m *metrics.Metrics) *Emitter {
	return &Emitter{
		last:    make(map[types.NamespacedName][]metrics.ViolationLabels),
		metrics: m,
	}
}

// Sync replaces the set of gauge series asserted for `obj` with `next`.
// Any label set previously emitted for `obj` that is not in `next` is
// deleted from the gauge before new ones are set. Order: delete first,
// set second, so transient `Set(0)` is never observable.
func (e *Emitter) Sync(obj types.NamespacedName, next []metrics.ViolationLabels) {
	e.mu.Lock()
	defer e.mu.Unlock()

	prev := e.last[obj]
	nextSet := indexLabels(next)

	for _, p := range prev {
		if _, keep := nextSet[labelKey(p)]; !keep {
			e.metrics.Violations.Delete(p.ToMap())
		}
	}
	for _, n := range next {
		e.metrics.Violations.With(n.ToMap()).Set(1)
	}
	if len(next) == 0 {
		delete(e.last, obj)
	} else {
		e.last[obj] = append([]metrics.ViolationLabels(nil), next...)
	}
}

// Forget drops every series for `obj`. Called on object delete.
func (e *Emitter) Forget(obj types.NamespacedName) {
	e.mu.Lock()
	defer e.mu.Unlock()
	for _, p := range e.last[obj] {
		e.metrics.Violations.Delete(p.ToMap())
	}
	delete(e.last, obj)
}

func indexLabels(s []metrics.ViolationLabels) map[string]struct{} {
	out := make(map[string]struct{}, len(s))
	for _, l := range s {
		out[labelKey(l)] = struct{}{}
	}
	return out
}

func labelKey(l metrics.ViolationLabels) string {
	return l.Namespace + "|" + l.Kind + "|" + l.Name + "|" +
		l.TriggerIndex + "|" + l.TriggerType + "|" + l.RuleID + "|" + l.Severity
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `go test ./internal/controller/... -v`
Expected: PASS — 4 tests.

- [ ] **Step 5: Commit**

```bash
git add internal/controller/emitter.go internal/controller/emitter_test.go
git commit -m "feat(kdw): per-object emitter with severity-flip cleanup"
```

---

### Task 12: Config watcher (controller-runtime CM reconciler)

**Files:**
- Create: `internal/config/watcher.go`

This task does not have unit tests — its behaviour is exercised in the integration test (Task 22). Manual verification at the end.

- [ ] **Step 1: Implement watcher.go**

```go
// internal/config/watcher.go
package config

import (
	"context"
	"fmt"

	corev1 "k8s.io/api/core/v1"
	"k8s.io/apimachinery/pkg/types"
	ctrl "sigs.k8s.io/controller-runtime"
	"sigs.k8s.io/controller-runtime/pkg/builder"
	"sigs.k8s.io/controller-runtime/pkg/client"
	"sigs.k8s.io/controller-runtime/pkg/log"
	"sigs.k8s.io/controller-runtime/pkg/predicate"
	"sigs.k8s.io/controller-runtime/pkg/reconcile"

	"github.com/wys1203/keda-labs/internal/metrics"
)

// ReEnqueueAll is called after a successful CM reload so that all
// watched SOs/SJs are re-linted with the new config (their gauge severity
// labels need to flip immediately, not on the next informer event).
type ReEnqueueAll func(context.Context)

type Watcher struct {
	Client       client.Client
	Namespace    string
	Name         string
	Store        *Store
	Metrics      *metrics.Metrics
	ReEnqueueAll ReEnqueueAll
	Recorder     EventRecorder
}

// EventRecorder is the slice of record.EventRecorder we use here. Defined
// as an interface to avoid pulling client-go's event sink into tests.
type EventRecorder interface {
	Eventf(object client.Object, eventType, reason, messageFmt string, args ...interface{})
}

func (w *Watcher) SetupWithManager(mgr ctrl.Manager) error {
	pred := predicate.NewPredicateFuncs(func(obj client.Object) bool {
		return obj.GetNamespace() == w.Namespace && obj.GetName() == w.Name
	})
	return ctrl.NewControllerManagedBy(mgr).
		For(&corev1.ConfigMap{}, builder.WithPredicates(pred)).
		Complete(w)
}

func (w *Watcher) Reconcile(ctx context.Context, req reconcile.Request) (reconcile.Result, error) {
	logger := log.FromContext(ctx).WithValues("configmap", req.NamespacedName)

	var cm corev1.ConfigMap
	if err := w.Client.Get(ctx, req.NamespacedName, &cm); err != nil {
		if isNotFound(err) {
			logger.Info("config map not found; falling back to empty config (built-in defaults)")
			w.Store.Store(&Config{})
			return reconcile.Result{}, nil
		}
		return reconcile.Result{}, err
	}

	raw, ok := cm.Data["config.yaml"]
	if !ok {
		err := fmt.Errorf("config.yaml key missing")
		w.handleErr(ctx, &cm, err)
		return reconcile.Result{}, nil
	}

	cfg, err := ParseYAML([]byte(raw))
	if err != nil {
		w.handleErr(ctx, &cm, err)
		return reconcile.Result{}, nil
	}

	w.Store.Store(cfg)
	w.Metrics.ConfigReloads.WithLabelValues("success").Inc()
	w.Metrics.ConfigGeneration.Set(float64(w.Store.Generation()))
	logger.Info("config reloaded", "generation", w.Store.Generation())
	if w.ReEnqueueAll != nil {
		w.ReEnqueueAll(ctx)
	}
	return reconcile.Result{}, nil
}

func (w *Watcher) handleErr(ctx context.Context, cm *corev1.ConfigMap, err error) {
	logger := log.FromContext(ctx)
	logger.Error(err, "config reload failed; keeping last good config")
	w.Metrics.ConfigReloads.WithLabelValues("error").Inc()
	if w.Recorder != nil {
		w.Recorder.Eventf(cm, corev1.EventTypeWarning, "InvalidConfig", "config reload failed: %v", err)
	}
}

// isNotFound is a tiny shim so this file doesn't need an explicit import on errors.IsNotFound.
func isNotFound(err error) bool {
	type apiErr interface{ Status() int32 }
	var n interface{ NotFound() bool }
	switch e := err.(type) {
	case apiErr:
		return e.Status() == 404
	default:
		_ = e
	}
	if n != nil && n.NotFound() {
		return true
	}
	// Fallback for typed apimachinery errors:
	return err != nil && (err.Error() == "not found" || containsNotFound(err.Error()))
}

func containsNotFound(s string) bool {
	return len(s) >= 9 && (s == "not found" || (len(s) > 9 && (s[len(s)-9:] == "not found" || stringContains(s, "not found"))))
}

func stringContains(s, sub string) bool {
	for i := 0; i+len(sub) <= len(s); i++ {
		if s[i:i+len(sub)] == sub {
			return true
		}
	}
	return false
}

// NamespacedName re-export so callers can construct selectors
// without importing apimachinery explicitly.
type NamespacedName = types.NamespacedName
```

> **Implementer note:** the `isNotFound` shim is intentionally permissive so this file compiles without depending on `k8s.io/apimachinery/pkg/api/errors` here. If you prefer, replace the body with `apierrors.IsNotFound(err)` after adding the import — equivalent and cleaner. Either works.

- [ ] **Step 2: Build to verify it compiles**

Run: `go build ./...`
Expected: exits 0.

- [ ] **Step 3: Commit**

```bash
git add internal/config/watcher.go
git commit -m "feat(kdw): config map watcher with hot-reload + last-good fallback"
```

---

### Task 13: Namespace cache

**Files:**
- Create: `internal/controller/namespace_cache.go`
- Create: `internal/controller/namespace_cache_test.go`

- [ ] **Step 1: Write the failing tests**

```go
// internal/controller/namespace_cache_test.go
package controller

import (
	"testing"

	"github.com/stretchr/testify/assert"
)

func TestNamespaceCache_GetMissing_ReturnsNil(t *testing.T) {
	c := NewNamespaceCache()
	assert.Nil(t, c.Get("nope"))
}

func TestNamespaceCache_PutThenGet_ReturnsCopy(t *testing.T) {
	c := NewNamespaceCache()
	c.Put("demo", map[string]string{"tier": "legacy"})

	got := c.Get("demo")
	assert.Equal(t, "legacy", got["tier"])

	// Mutating the returned map must NOT corrupt the cache.
	got["tier"] = "prod"
	assert.Equal(t, "legacy", c.Get("demo")["tier"])
}

func TestNamespaceCache_Delete(t *testing.T) {
	c := NewNamespaceCache()
	c.Put("demo", map[string]string{"a": "b"})
	c.Delete("demo")
	assert.Nil(t, c.Get("demo"))
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `go test ./internal/controller/... -run TestNamespaceCache -v`
Expected: FAIL.

- [ ] **Step 3: Implement namespace_cache.go**

```go
// internal/controller/namespace_cache.go
package controller

import "sync"

type NamespaceCache struct {
	mu    sync.RWMutex
	store map[string]map[string]string
}

func NewNamespaceCache() *NamespaceCache {
	return &NamespaceCache{store: make(map[string]map[string]string)}
}

func (c *NamespaceCache) Get(ns string) map[string]string {
	c.mu.RLock()
	defer c.mu.RUnlock()
	src, ok := c.store[ns]
	if !ok {
		return nil
	}
	out := make(map[string]string, len(src))
	for k, v := range src {
		out[k] = v
	}
	return out
}

func (c *NamespaceCache) Put(ns string, labels map[string]string) {
	c.mu.Lock()
	defer c.mu.Unlock()
	cp := make(map[string]string, len(labels))
	for k, v := range labels {
		cp[k] = v
	}
	c.store[ns] = cp
}

func (c *NamespaceCache) Delete(ns string) {
	c.mu.Lock()
	defer c.mu.Unlock()
	delete(c.store, ns)
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `go test ./internal/controller/... -v`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add internal/controller/namespace_cache.go internal/controller/namespace_cache_test.go
git commit -m "feat(kdw): namespace label cache"
```

---

### Task 14: Namespace reconciler (re-enqueue affected SO/SJ on label change)

**Files:**
- Create: `internal/controller/namespace_reconciler.go`

No unit test here — covered by integration test in Task 22.

- [ ] **Step 1: Implement namespace_reconciler.go**

```go
// internal/controller/namespace_reconciler.go
package controller

import (
	"context"

	corev1 "k8s.io/api/core/v1"
	ctrl "sigs.k8s.io/controller-runtime"
	"sigs.k8s.io/controller-runtime/pkg/client"
	"sigs.k8s.io/controller-runtime/pkg/log"
	"sigs.k8s.io/controller-runtime/pkg/reconcile"

	kedav1alpha1 "github.com/kedacore/keda/v2/apis/keda/v1alpha1"
)

// NamespaceReconciler keeps NamespaceCache in sync and triggers a re-lint
// of every SO/SJ in the namespace whenever its labels change. (Add/remove
// of a `tier=legacy`-style override label must flip gauge severity for
// every affected object within one reconcile cycle, not at next event.)
type NamespaceReconciler struct {
	Client client.Client
	Cache  *NamespaceCache
	Enq    Enqueuer
}

// Enqueuer triggers reconciliation of a single SO or SJ by NamespacedName.
type Enqueuer interface {
	EnqueueAllInNamespace(ctx context.Context, ns string)
}

func (r *NamespaceReconciler) SetupWithManager(mgr ctrl.Manager) error {
	return ctrl.NewControllerManagedBy(mgr).
		For(&corev1.Namespace{}).
		Complete(r)
}

func (r *NamespaceReconciler) Reconcile(ctx context.Context, req reconcile.Request) (reconcile.Result, error) {
	logger := log.FromContext(ctx)

	var ns corev1.Namespace
	if err := r.Client.Get(ctx, req.NamespacedName, &ns); err != nil {
		// On delete, drop cache entry; SO/SJ in that ns will also be torn
		// down by k8s, which fires Delete events the SO/SJ reconciler handles.
		r.Cache.Delete(req.Name)
		return reconcile.Result{}, client.IgnoreNotFound(err)
	}

	r.Cache.Put(ns.Name, ns.Labels)
	logger.V(1).Info("namespace cache updated", "ns", ns.Name)

	// Re-enqueue all SOs/SJs in this ns so the controller re-lints with
	// the new labels.
	if r.Enq != nil {
		r.Enq.EnqueueAllInNamespace(ctx, ns.Name)
	}
	return reconcile.Result{}, nil
}

// Convenience: a list-and-fan-out helper for callers that need to know
// what SO/SJ exist in a given namespace.
func ListAllInNamespace(ctx context.Context, c client.Client, ns string) ([]client.Object, error) {
	var sos kedav1alpha1.ScaledObjectList
	if err := c.List(ctx, &sos, client.InNamespace(ns)); err != nil {
		return nil, err
	}
	var sjs kedav1alpha1.ScaledJobList
	if err := c.List(ctx, &sjs, client.InNamespace(ns)); err != nil {
		return nil, err
	}
	out := make([]client.Object, 0, len(sos.Items)+len(sjs.Items))
	for i := range sos.Items {
		out = append(out, &sos.Items[i])
	}
	for i := range sjs.Items {
		out = append(out, &sjs.Items[i])
	}
	return out, nil
}
```

- [ ] **Step 2: Build to verify it compiles**

Run: `go build ./...`
Expected: exits 0.

- [ ] **Step 3: Commit**

```bash
git add internal/controller/namespace_reconciler.go
git commit -m "feat(kdw): namespace reconciler re-enqueues affected workloads"
```

---

### Task 15: ScaledObject + ScaledJob reconcilers

**Files:**
- Create: `internal/controller/scaledobject_reconciler.go`
- Create: `internal/controller/scaledjob_reconciler.go`
- Create: `internal/controller/enqueuer.go`

No unit test here — covered by integration test in Task 22. Behaviour is mostly k8s-client + emitter glue; the emitter has its own coverage.

- [ ] **Step 1: Implement enqueuer.go**

```go
// internal/controller/enqueuer.go
package controller

import (
	"context"
	"sync"

	"k8s.io/apimachinery/pkg/types"
	"sigs.k8s.io/controller-runtime/pkg/client"
	"sigs.k8s.io/controller-runtime/pkg/event"

	kedav1alpha1 "github.com/kedacore/keda/v2/apis/keda/v1alpha1"
)

// FanOut owns the controller-runtime Source channels for SO and SJ
// reconcilers. EnqueueAllInNamespace and EnqueueAll synthesize events
// onto those channels so the same workqueue path handles them.
type FanOut struct {
	mu  sync.Mutex
	soC chan event.GenericEvent
	sjC chan event.GenericEvent
	c   client.Client
}

func NewFanOut(c client.Client) *FanOut {
	return &FanOut{
		c:   c,
		soC: make(chan event.GenericEvent, 1024),
		sjC: make(chan event.GenericEvent, 1024),
	}
}

func (f *FanOut) SOChan() <-chan event.GenericEvent { return f.soC }
func (f *FanOut) SJChan() <-chan event.GenericEvent { return f.sjC }

func (f *FanOut) EnqueueAllInNamespace(ctx context.Context, ns string) {
	var sos kedav1alpha1.ScaledObjectList
	if err := f.c.List(ctx, &sos, client.InNamespace(ns)); err == nil {
		for i := range sos.Items {
			f.soC <- event.GenericEvent{Object: &sos.Items[i]}
		}
	}
	var sjs kedav1alpha1.ScaledJobList
	if err := f.c.List(ctx, &sjs, client.InNamespace(ns)); err == nil {
		for i := range sjs.Items {
			f.sjC <- event.GenericEvent{Object: &sjs.Items[i]}
		}
	}
}

func (f *FanOut) EnqueueAll(ctx context.Context) {
	var sos kedav1alpha1.ScaledObjectList
	if err := f.c.List(ctx, &sos); err == nil {
		for i := range sos.Items {
			f.soC <- event.GenericEvent{Object: &sos.Items[i]}
		}
	}
	var sjs kedav1alpha1.ScaledJobList
	if err := f.c.List(ctx, &sjs); err == nil {
		for i := range sjs.Items {
			f.sjC <- event.GenericEvent{Object: &sjs.Items[i]}
		}
	}
}

// Helper for tests / consumers that want to reconcile a specific key.
func keyOf(o client.Object) types.NamespacedName {
	return types.NamespacedName{Namespace: o.GetNamespace(), Name: o.GetName()}
}
```

- [ ] **Step 2: Implement scaledobject_reconciler.go**

```go
// internal/controller/scaledobject_reconciler.go
package controller

import (
	"context"
	"fmt"
	"strconv"

	apierrors "k8s.io/apimachinery/pkg/api/errors"
	ctrl "sigs.k8s.io/controller-runtime"
	"sigs.k8s.io/controller-runtime/pkg/client"
	"sigs.k8s.io/controller-runtime/pkg/event"
	"sigs.k8s.io/controller-runtime/pkg/handler"
	"sigs.k8s.io/controller-runtime/pkg/reconcile"
	"sigs.k8s.io/controller-runtime/pkg/source"

	kedav1alpha1 "github.com/kedacore/keda/v2/apis/keda/v1alpha1"

	"github.com/wys1203/keda-labs/internal/config"
	"github.com/wys1203/keda-labs/internal/metrics"
	"github.com/wys1203/keda-labs/internal/rules"
)

type ScaledObjectReconciler struct {
	Client    client.Client
	Config    *config.Store
	Cache     *NamespaceCache
	Emitter   *Emitter
	ExtraSrc  <-chan event.GenericEvent
}

func (r *ScaledObjectReconciler) SetupWithManager(mgr ctrl.Manager) error {
	c := ctrl.NewControllerManagedBy(mgr).For(&kedav1alpha1.ScaledObject{})
	if r.ExtraSrc != nil {
		c = c.Watches(source.Channel(r.ExtraSrc, &handler.EnqueueRequestForObject{}))
	}
	return c.Complete(r)
}

func (r *ScaledObjectReconciler) Reconcile(ctx context.Context, req reconcile.Request) (reconcile.Result, error) {
	var so kedav1alpha1.ScaledObject
	if err := r.Client.Get(ctx, req.NamespacedName, &so); err != nil {
		if apierrors.IsNotFound(err) {
			r.Emitter.Forget(req.NamespacedName)
			return reconcile.Result{}, nil
		}
		return reconcile.Result{}, err
	}
	target := rules.Target{
		Kind: "ScaledObject", Namespace: so.Namespace, Name: so.Name, Triggers: so.Spec.Triggers,
	}
	r.Emitter.Sync(req.NamespacedName, r.violationsToLabels(target))
	return reconcile.Result{}, nil
}

func (r *ScaledObjectReconciler) violationsToLabels(t rules.Target) []metrics.ViolationLabels {
	cfg := r.Config.Load()
	nsLabels := r.Cache.Get(t.Namespace)
	vs := rules.LintAll(t)
	out := make([]metrics.ViolationLabels, 0, len(vs))
	for _, v := range vs {
		sev := cfg.EffectiveSeverity(v.RuleID, t.Namespace, nsLabels)
		out = append(out, metrics.ViolationLabels{
			Namespace: t.Namespace, Kind: t.Kind, Name: t.Name,
			TriggerIndex: strconv.Itoa(v.TriggerIndex),
			TriggerType:  v.TriggerType, RuleID: v.RuleID,
			Severity: string(sev),
		})
	}
	return out
}

// Used by main.go to wire the channel source.
func (r *ScaledObjectReconciler) String() string {
	return fmt.Sprintf("ScaledObjectReconciler{cache=%p}", r.Cache)
}
```

- [ ] **Step 3: Implement scaledjob_reconciler.go**

```go
// internal/controller/scaledjob_reconciler.go
package controller

import (
	"context"
	"strconv"

	apierrors "k8s.io/apimachinery/pkg/api/errors"
	ctrl "sigs.k8s.io/controller-runtime"
	"sigs.k8s.io/controller-runtime/pkg/client"
	"sigs.k8s.io/controller-runtime/pkg/event"
	"sigs.k8s.io/controller-runtime/pkg/handler"
	"sigs.k8s.io/controller-runtime/pkg/reconcile"
	"sigs.k8s.io/controller-runtime/pkg/source"

	kedav1alpha1 "github.com/kedacore/keda/v2/apis/keda/v1alpha1"

	"github.com/wys1203/keda-labs/internal/config"
	"github.com/wys1203/keda-labs/internal/metrics"
	"github.com/wys1203/keda-labs/internal/rules"
)

type ScaledJobReconciler struct {
	Client   client.Client
	Config   *config.Store
	Cache    *NamespaceCache
	Emitter  *Emitter
	ExtraSrc <-chan event.GenericEvent
}

func (r *ScaledJobReconciler) SetupWithManager(mgr ctrl.Manager) error {
	c := ctrl.NewControllerManagedBy(mgr).For(&kedav1alpha1.ScaledJob{})
	if r.ExtraSrc != nil {
		c = c.Watches(source.Channel(r.ExtraSrc, &handler.EnqueueRequestForObject{}))
	}
	return c.Complete(r)
}

func (r *ScaledJobReconciler) Reconcile(ctx context.Context, req reconcile.Request) (reconcile.Result, error) {
	var sj kedav1alpha1.ScaledJob
	if err := r.Client.Get(ctx, req.NamespacedName, &sj); err != nil {
		if apierrors.IsNotFound(err) {
			r.Emitter.Forget(req.NamespacedName)
			return reconcile.Result{}, nil
		}
		return reconcile.Result{}, err
	}
	target := rules.Target{
		Kind: "ScaledJob", Namespace: sj.Namespace, Name: sj.Name, Triggers: sj.Spec.Triggers,
	}
	r.Emitter.Sync(req.NamespacedName, r.violationsToLabels(target))
	return reconcile.Result{}, nil
}

func (r *ScaledJobReconciler) violationsToLabels(t rules.Target) []metrics.ViolationLabels {
	cfg := r.Config.Load()
	nsLabels := r.Cache.Get(t.Namespace)
	vs := rules.LintAll(t)
	out := make([]metrics.ViolationLabels, 0, len(vs))
	for _, v := range vs {
		sev := cfg.EffectiveSeverity(v.RuleID, t.Namespace, nsLabels)
		out = append(out, metrics.ViolationLabels{
			Namespace: t.Namespace, Kind: t.Kind, Name: t.Name,
			TriggerIndex: strconv.Itoa(v.TriggerIndex),
			TriggerType:  v.TriggerType, RuleID: v.RuleID,
			Severity: string(sev),
		})
	}
	return out
}
```

- [ ] **Step 4: Build to verify**

Run: `go build ./...`
Expected: exits 0.

- [ ] **Step 5: Commit**

```bash
git add internal/controller/enqueuer.go internal/controller/scaledobject_reconciler.go internal/controller/scaledjob_reconciler.go
git commit -m "feat(kdw): SO/SJ reconcilers + fan-out enqueuer"
```

---

### Task 16: main.go — manager wiring

**Files:**
- Modify: `cmd/keda-deprecation-webhook/main.go`

- [ ] **Step 1: Replace stub main.go with real wiring**

```go
// cmd/keda-deprecation-webhook/main.go
package main

import (
	"context"
	"flag"
	"net/http"
	"os"

	"go.uber.org/zap/zapcore"
	corev1 "k8s.io/api/core/v1"
	"k8s.io/apimachinery/pkg/runtime"
	utilruntime "k8s.io/apimachinery/pkg/util/runtime"
	clientgoscheme "k8s.io/client-go/kubernetes/scheme"
	ctrl "sigs.k8s.io/controller-runtime"
	"sigs.k8s.io/controller-runtime/pkg/healthz"
	"sigs.k8s.io/controller-runtime/pkg/log/zap"
	"sigs.k8s.io/controller-runtime/pkg/manager"
	"sigs.k8s.io/controller-runtime/pkg/webhook"

	"github.com/prometheus/client_golang/prometheus/promhttp"

	kedav1alpha1 "github.com/kedacore/keda/v2/apis/keda/v1alpha1"

	"github.com/wys1203/keda-labs/internal/config"
	"github.com/wys1203/keda-labs/internal/controller"
	whk "github.com/wys1203/keda-labs/internal/webhook"
	"github.com/wys1203/keda-labs/internal/metrics"
)

var scheme = runtime.NewScheme()

func init() {
	utilruntime.Must(clientgoscheme.AddToScheme(scheme))
	utilruntime.Must(kedav1alpha1.AddToScheme(scheme))
	utilruntime.Must(corev1.AddToScheme(scheme))
}

func main() {
	var (
		metricsAddr = flag.String("metrics-bind-address", ":8080", "")
		probeAddr   = flag.String("health-probe-bind-address", ":8080", "")
		webhookPort = flag.Int("webhook-port", 9443, "")
		certDir     = flag.String("cert-dir", "/etc/webhook/certs", "")
		cmName      = flag.String("config-map-name", "keda-deprecation-webhook-config", "")
		msgURL      = flag.String("reject-message-url", os.Getenv("REJECT_MESSAGE_URL"), "")
		leaderElect = flag.Bool("leader-elect", true, "")
	)
	flag.Parse()
	ctrl.SetLogger(zap.New(zap.UseDevMode(false), zap.Level(zapcore.InfoLevel)))

	ns := os.Getenv("NAMESPACE")
	if ns == "" {
		ctrl.Log.Error(nil, "NAMESPACE env var unset")
		os.Exit(2)
	}

	mgr, err := ctrl.NewManager(ctrl.GetConfigOrDie(), manager.Options{
		Scheme:                  scheme,
		HealthProbeBindAddress:  *probeAddr,
		LeaderElection:          *leaderElect,
		LeaderElectionID:        "keda-deprecation-webhook.keda.sh",
		LeaderElectionNamespace: ns,
		WebhookServer: webhook.NewServer(webhook.Options{
			Port:    *webhookPort,
			CertDir: *certDir,
		}),
	})
	if err != nil {
		ctrl.Log.Error(err, "manager init failed")
		os.Exit(1)
	}

	m := metrics.New()
	store := config.NewStore()
	nsCache := controller.NewNamespaceCache()
	emitter := controller.NewEmitter(m)
	fanOut := controller.NewFanOut(mgr.GetClient())

	// Webhook server: runs on every replica, no leader election dependency.
	mgr.GetWebhookServer().Register(
		"/validate-keda-sh-v1alpha1",
		&webhook.Admission{Handler: &whk.Handler{
			Config: store, NSCache: nsCache, Metrics: m, MsgURL: *msgURL,
		}},
	)

	// Config watcher (every replica reads its own config to keep webhook
	// admission consistent across replicas).
	if err := (&config.Watcher{
		Client: mgr.GetClient(), Namespace: ns, Name: *cmName,
		Store: store, Metrics: m,
		ReEnqueueAll: fanOut.EnqueueAll,
	}).SetupWithManager(mgr); err != nil {
		ctrl.Log.Error(err, "config watcher setup failed")
		os.Exit(1)
	}

	// Namespace reconciler (every replica keeps its own NS cache).
	if err := (&controller.NamespaceReconciler{
		Client: mgr.GetClient(), Cache: nsCache, Enq: fanOut,
	}).SetupWithManager(mgr); err != nil {
		ctrl.Log.Error(err, "ns reconciler setup failed")
		os.Exit(1)
	}

	// SO/SJ reconcilers — leader-only (gauge emission must be single-writer).
	if err := mgr.Add(manager.RunnableFunc(func(ctx context.Context) error {
		<-ctx.Done()
		return nil
	})); err != nil {
		// noop — we use the manager's leader election directly via the
		// reconciler `For` builder; controller-runtime obeys NeedLeaderElection.
		_ = err
	}
	if err := (&controller.ScaledObjectReconciler{
		Client: mgr.GetClient(), Config: store, Cache: nsCache, Emitter: emitter, ExtraSrc: fanOut.SOChan(),
	}).SetupWithManager(mgr); err != nil {
		ctrl.Log.Error(err, "SO reconciler setup failed")
		os.Exit(1)
	}
	if err := (&controller.ScaledJobReconciler{
		Client: mgr.GetClient(), Config: store, Cache: nsCache, Emitter: emitter, ExtraSrc: fanOut.SJChan(),
	}).SetupWithManager(mgr); err != nil {
		ctrl.Log.Error(err, "SJ reconciler setup failed")
		os.Exit(1)
	}

	if err := mgr.AddHealthzCheck("healthz", healthz.Ping); err != nil {
		ctrl.Log.Error(err, "healthz setup")
		os.Exit(1)
	}
	if err := mgr.AddReadyzCheck("readyz", healthz.Ping); err != nil {
		ctrl.Log.Error(err, "readyz setup")
		os.Exit(1)
	}

	// Metrics server: serve KDW's own registry on /metrics.
	go func() {
		mux := http.NewServeMux()
		mux.Handle("/metrics", promhttp.HandlerFor(m.Registry, promhttp.HandlerOpts{}))
		_ = http.ListenAndServe(*metricsAddr, mux)
	}()

	ctrl.Log.Info("starting manager", "namespace", ns)
	if err := mgr.Start(ctrl.SetupSignalHandler()); err != nil {
		ctrl.Log.Error(err, "manager exited")
		os.Exit(1)
	}
}
```

> **Note:** controller-runtime's manager.Options health/metrics handling has changed across versions. If `HealthProbeBindAddress` and the inline metrics server collide on `:8080`, drop one — the goroutine version above is independent of mgr's metrics binding. Keep the goroutine.

- [ ] **Step 2: Build**

Run: `go build ./...`
Expected: exits 0.

- [ ] **Step 3: Commit**

```bash
git add cmd/keda-deprecation-webhook/main.go go.mod go.sum
git commit -m "feat(kdw): main entrypoint wiring manager + webhook + reconcilers"
```

---

### Task 17: Dockerfile

**Files:**
- Create: `Dockerfile`

- [ ] **Step 1: Write Dockerfile**

```dockerfile
# Dockerfile
# syntax=docker/dockerfile:1.6
FROM golang:1.23-alpine AS build
WORKDIR /src
COPY go.mod go.sum ./
RUN --mount=type=cache,target=/go/pkg/mod \
    --mount=type=cache,target=/root/.cache/go-build \
    go mod download
COPY cmd ./cmd
COPY internal ./internal
RUN --mount=type=cache,target=/go/pkg/mod \
    --mount=type=cache,target=/root/.cache/go-build \
    CGO_ENABLED=0 GOOS=linux go build -trimpath -ldflags="-s -w" \
      -o /out/keda-deprecation-webhook ./cmd/keda-deprecation-webhook

FROM gcr.io/distroless/static-debian12:nonroot
COPY --from=build /out/keda-deprecation-webhook /keda-deprecation-webhook
USER 65532:65532
ENTRYPOINT ["/keda-deprecation-webhook"]
```

- [ ] **Step 2: Build and verify image runs**

```bash
docker build -t keda-deprecation-webhook:dev .
docker run --rm keda-deprecation-webhook:dev --help 2>&1 | head -10
```

Expected: image builds; running with `--help` exits cleanly with flag descriptions.

- [ ] **Step 3: Commit**

```bash
git add Dockerfile
git commit -m "feat(kdw): Dockerfile (multi-stage, distroless)"
```

---

### Task 18: Manifests — namespace + RBAC

**Files:**
- Create: `manifests/keda-deprecation-webhook/namespace.yaml`
- Create: `manifests/keda-deprecation-webhook/rbac.yaml`

- [ ] **Step 1: Write namespace.yaml**

```yaml
# manifests/keda-deprecation-webhook/namespace.yaml
apiVersion: v1
kind: Namespace
metadata:
  name: keda-system
  labels:
    prodsuite: Platform
```

- [ ] **Step 2: Write rbac.yaml**

```yaml
# manifests/keda-deprecation-webhook/rbac.yaml
apiVersion: v1
kind: ServiceAccount
metadata:
  name: keda-deprecation-webhook
  namespace: keda-system
---
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: keda-deprecation-webhook
  namespace: keda-system
rules:
  - apiGroups: [""]
    resources: ["configmaps"]
    resourceNames: ["keda-deprecation-webhook-config"]
    verbs: ["get", "list", "watch"]
  - apiGroups: [""]
    resources: ["events"]
    verbs: ["create", "patch"]
  - apiGroups: ["coordination.k8s.io"]
    resources: ["leases"]
    verbs: ["get", "list", "watch", "create", "update", "patch"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: keda-deprecation-webhook
  namespace: keda-system
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: Role
  name: keda-deprecation-webhook
subjects:
  - kind: ServiceAccount
    name: keda-deprecation-webhook
    namespace: keda-system
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: keda-deprecation-webhook
rules:
  - apiGroups: [""]
    resources: ["namespaces"]
    verbs: ["get", "list", "watch"]
  - apiGroups: ["keda.sh"]
    resources: ["scaledobjects", "scaledjobs"]
    verbs: ["get", "list", "watch"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: keda-deprecation-webhook
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: keda-deprecation-webhook
subjects:
  - kind: ServiceAccount
    name: keda-deprecation-webhook
    namespace: keda-system
```

- [ ] **Step 3: Commit**

```bash
git add manifests/keda-deprecation-webhook/namespace.yaml manifests/keda-deprecation-webhook/rbac.yaml
git commit -m "feat(kdw): namespace + RBAC manifests"
```

---

### Task 19: Manifests — cert-manager Issuer + Certificate

**Files:**
- Create: `manifests/keda-deprecation-webhook/certificate.yaml`

- [ ] **Step 1: Write certificate.yaml**

```yaml
# manifests/keda-deprecation-webhook/certificate.yaml
apiVersion: cert-manager.io/v1
kind: Issuer
metadata:
  name: kdw-selfsigned
  namespace: keda-system
spec:
  selfSigned: {}
---
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: kdw-serving-cert
  namespace: keda-system
spec:
  secretName: kdw-tls
  duration: 8760h
  renewBefore: 720h
  dnsNames:
    - keda-deprecation-webhook.keda-system.svc
    - keda-deprecation-webhook.keda-system.svc.cluster.local
  issuerRef:
    name: kdw-selfsigned
    kind: Issuer
```

- [ ] **Step 2: Commit**

```bash
git add manifests/keda-deprecation-webhook/certificate.yaml
git commit -m "feat(kdw): cert-manager Issuer + Certificate"
```

---

### Task 20: Manifests — ConfigMap, Service, Deployment, PDB, VWC

**Files:**
- Create: `manifests/keda-deprecation-webhook/configmap.yaml`
- Create: `manifests/keda-deprecation-webhook/service.yaml`
- Create: `manifests/keda-deprecation-webhook/deployment.yaml`
- Create: `manifests/keda-deprecation-webhook/pdb.yaml`
- Create: `manifests/keda-deprecation-webhook/validatingwebhookconfiguration.yaml`

- [ ] **Step 1: Write configmap.yaml**

```yaml
# manifests/keda-deprecation-webhook/configmap.yaml
# Lab default config:
#   - KEDA001 default severity = error (admission rejects on CREATE)
#   - legacy-cpu namespace is exempted to severity=warn so the existing
#     deprecated SO (manifests/legacy-cpu/) demonstrates the warn-mode
#     code path without being permanently blocked.
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
          - names: ["legacy-cpu"]
            severity: warn
```

- [ ] **Step 2: Write service.yaml**

```yaml
# manifests/keda-deprecation-webhook/service.yaml
apiVersion: v1
kind: Service
metadata:
  name: keda-deprecation-webhook
  namespace: keda-system
  labels:
    app.kubernetes.io/name: keda-deprecation-webhook
  annotations:
    prometheus.io/scrape: "true"
    prometheus.io/port: "8080"
    prometheus.io/path: /metrics
spec:
  selector:
    app.kubernetes.io/name: keda-deprecation-webhook
  ports:
    - name: webhook
      port: 443
      targetPort: 9443
      protocol: TCP
    - name: metrics
      port: 8080
      targetPort: 8080
      protocol: TCP
```

- [ ] **Step 3: Write deployment.yaml**

```yaml
# manifests/keda-deprecation-webhook/deployment.yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: keda-deprecation-webhook
  namespace: keda-system
  labels:
    app.kubernetes.io/name: keda-deprecation-webhook
spec:
  replicas: 2
  selector:
    matchLabels:
      app.kubernetes.io/name: keda-deprecation-webhook
  strategy:
    rollingUpdate:
      maxSurge: 1
      maxUnavailable: 0
    type: RollingUpdate
  template:
    metadata:
      labels:
        app.kubernetes.io/name: keda-deprecation-webhook
    spec:
      serviceAccountName: keda-deprecation-webhook
      containers:
        - name: webhook
          image: keda-deprecation-webhook:dev
          imagePullPolicy: IfNotPresent
          args:
            - --metrics-bind-address=:8080
            - --health-probe-bind-address=:8081
            - --webhook-port=9443
            - --cert-dir=/etc/webhook/certs
            - --config-map-name=keda-deprecation-webhook-config
          env:
            - name: NAMESPACE
              valueFrom:
                fieldRef:
                  fieldPath: metadata.namespace
            - name: REJECT_MESSAGE_URL
              value: ""
          ports:
            - name: webhook
              containerPort: 9443
            - name: metrics
              containerPort: 8080
            - name: probes
              containerPort: 8081
          livenessProbe:
            httpGet: { path: /healthz, port: probes }
            initialDelaySeconds: 5
            periodSeconds: 10
          readinessProbe:
            httpGet: { path: /readyz, port: probes }
            initialDelaySeconds: 5
            periodSeconds: 5
          resources:
            requests: { cpu: 50m, memory: 64Mi }
            limits:   { cpu: 200m, memory: 256Mi }
          volumeMounts:
            - name: certs
              mountPath: /etc/webhook/certs
              readOnly: true
      volumes:
        - name: certs
          secret:
            secretName: kdw-tls
```

> **Note on probes binding:** the inline metrics goroutine in main.go binds `:8080`. To avoid colliding with `HealthProbeBindAddress`, the args above point probes to `:8081` while metrics stays on `:8080`. If main.go uses the manager's built-in metrics handler instead, drop the goroutine and unify. Keep these two ports distinct in any case.

- [ ] **Step 4: Write pdb.yaml**

```yaml
# manifests/keda-deprecation-webhook/pdb.yaml
apiVersion: policy/v1
kind: PodDisruptionBudget
metadata:
  name: keda-deprecation-webhook
  namespace: keda-system
spec:
  maxUnavailable: 1
  selector:
    matchLabels:
      app.kubernetes.io/name: keda-deprecation-webhook
```

- [ ] **Step 5: Write validatingwebhookconfiguration.yaml**

```yaml
# manifests/keda-deprecation-webhook/validatingwebhookconfiguration.yaml
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

- [ ] **Step 6: Commit**

```bash
git add manifests/keda-deprecation-webhook/configmap.yaml \
        manifests/keda-deprecation-webhook/service.yaml \
        manifests/keda-deprecation-webhook/deployment.yaml \
        manifests/keda-deprecation-webhook/pdb.yaml \
        manifests/keda-deprecation-webhook/validatingwebhookconfiguration.yaml
git commit -m "feat(kdw): config, service, deployment, PDB, VWC manifests"
```

---

### Task 21: Demo workload — `demo-deprecated`

**Files:**
- Create: `manifests/demo-deprecated/namespace.yaml`
- Create: `manifests/demo-deprecated/deployment.yaml`
- Create: `manifests/demo-deprecated/scaledobject.yaml`

- [ ] **Step 1: namespace.yaml**

```yaml
apiVersion: v1
kind: Namespace
metadata:
  name: demo-deprecated
  labels:
    prodsuite: Platform
```

- [ ] **Step 2: deployment.yaml**

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: cpu-deprecated
  namespace: demo-deprecated
  labels:
    app: cpu-deprecated
spec:
  replicas: 1
  selector:
    matchLabels: { app: cpu-deprecated }
  template:
    metadata:
      labels: { app: cpu-deprecated }
    spec:
      containers:
        - name: app
          image: registry.k8s.io/pause:3.9
          resources:
            requests: { cpu: 50m, memory: 32Mi }
            limits:   { cpu: 200m, memory: 64Mi }
```

- [ ] **Step 3: scaledobject.yaml**

```yaml
# Deliberately uses the DEPRECATED `metadata.type` form. Applied via
# `make demo-deprecated` after the webhook is up; expected to be
# REJECTED by the webhook (KEDA001, severity=error in this namespace).
apiVersion: keda.sh/v1alpha1
kind: ScaledObject
metadata:
  name: cpu-deprecated
  namespace: demo-deprecated
spec:
  scaleTargetRef:
    name: cpu-deprecated
  pollingInterval: 15
  cooldownPeriod: 30
  minReplicaCount: 1
  maxReplicaCount: 6
  triggers:
    - type: cpu
      metadata:
        type: Utilization
        value: "50"
```

- [ ] **Step 4: Commit**

```bash
git add manifests/demo-deprecated/
git commit -m "feat(kdw): demo-deprecated workload (reject-mode demo)"
```

---

### Task 22: Integration tests (envtest)

**Files:**
- Create: `test/integration/suite_test.go`
- Create: `test/integration/webhook_test.go`

- [ ] **Step 1: Pull envtest binaries (one-time setup)**

```bash
go install sigs.k8s.io/controller-runtime/tools/setup-envtest@latest
$(go env GOPATH)/bin/setup-envtest use 1.30.x -p path
# Capture the printed path and export it for tests:
export KUBEBUILDER_ASSETS="$($(go env GOPATH)/bin/setup-envtest use 1.30.x -p path)"
```

- [ ] **Step 2: Write suite_test.go**

```go
// test/integration/suite_test.go
//go:build integration

package integration

import (
	"context"
	"path/filepath"
	"testing"
	"time"

	"github.com/stretchr/testify/require"
	corev1 "k8s.io/api/core/v1"
	"k8s.io/apimachinery/pkg/runtime"
	clientgoscheme "k8s.io/client-go/kubernetes/scheme"
	"sigs.k8s.io/controller-runtime/pkg/client"
	"sigs.k8s.io/controller-runtime/pkg/envtest"
	logf "sigs.k8s.io/controller-runtime/pkg/log"
	"sigs.k8s.io/controller-runtime/pkg/log/zap"

	kedav1alpha1 "github.com/kedacore/keda/v2/apis/keda/v1alpha1"
)

type TestEnv struct {
	Env    *envtest.Environment
	Client client.Client
}

func StartEnv(t *testing.T) *TestEnv {
	t.Helper()
	logf.SetLogger(zap.New(zap.UseDevMode(true)))

	scheme := runtime.NewScheme()
	require.NoError(t, clientgoscheme.AddToScheme(scheme))
	require.NoError(t, corev1.AddToScheme(scheme))
	require.NoError(t, kedav1alpha1.AddToScheme(scheme))

	env := &envtest.Environment{
		CRDDirectoryPaths: []string{
			// Point at the kedacore CRDs vendored or downloaded for tests.
			// One easy path: copy crds from the kedacore module's deploy
			// directory at test setup time, or check them into testdata/.
			filepath.Join("..", "..", "test", "testdata", "crds"),
		},
		ErrorIfCRDPathMissing: true,
	}
	cfg, err := env.Start()
	require.NoError(t, err)

	c, err := client.New(cfg, client.Options{Scheme: scheme})
	require.NoError(t, err)

	t.Cleanup(func() {
		_ = env.Stop()
	})
	return &TestEnv{Env: env, Client: c}
}

func mustCreateNamespace(t *testing.T, c client.Client, name string, labels map[string]string) {
	t.Helper()
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	require.NoError(t, c.Create(ctx, &corev1.Namespace{
		ObjectMeta: metav1Object(name, labels),
	}))
}
```

> **Implementer note:** add a small helper file `test/integration/helpers.go` with `metav1Object(name, labels)` returning a `metav1.ObjectMeta`. Standard Go boilerplate — keep it inline in `suite_test.go` if you prefer.

- [ ] **Step 3: Write webhook_test.go**

```go
// test/integration/webhook_test.go
//go:build integration

package integration

import (
	"context"
	"testing"
	"time"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
	apierrors "k8s.io/apimachinery/pkg/api/errors"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"

	kedav1alpha1 "github.com/kedacore/keda/v2/apis/keda/v1alpha1"
)

// These tests run against a *bare* envtest apiserver; the KDW binary is
// not started by them. They verify CRD round-trips and basic shapes —
// the webhook decision path is covered by handler_test.go.
//
// To run an end-to-end test against a real KDW pod, use the lab E2E
// (`make verify-webhook`) — see Task 23.

func TestEnvtest_AppliesScaledObject(t *testing.T) {
	te := StartEnv(t)
	mustCreateNamespace(t, te.Client, "demo", nil)

	so := &kedav1alpha1.ScaledObject{
		ObjectMeta: metav1.ObjectMeta{Name: "x", Namespace: "demo"},
		Spec: kedav1alpha1.ScaledObjectSpec{
			ScaleTargetRef: &kedav1alpha1.ScaleTarget{Name: "x"},
			Triggers: []kedav1alpha1.ScaleTriggers{
				{Type: "cpu", MetricType: "Utilization", Metadata: map[string]string{"value": "50"}},
			},
		},
	}
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	require.NoError(t, te.Client.Create(ctx, so))

	got := &kedav1alpha1.ScaledObject{}
	require.NoError(t, te.Client.Get(ctx, types.NamespacedName{Namespace: "demo", Name: "x"}, got))
	assert.Equal(t, "cpu", string(got.Spec.Triggers[0].Type))
}

func TestEnvtest_DeleteCleanly(t *testing.T) {
	te := StartEnv(t)
	mustCreateNamespace(t, te.Client, "demo2", nil)
	so := &kedav1alpha1.ScaledObject{
		ObjectMeta: metav1.ObjectMeta{Name: "y", Namespace: "demo2"},
		Spec: kedav1alpha1.ScaledObjectSpec{
			ScaleTargetRef: &kedav1alpha1.ScaleTarget{Name: "y"},
		},
	}
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	require.NoError(t, te.Client.Create(ctx, so))
	require.NoError(t, te.Client.Delete(ctx, so))
	got := &kedav1alpha1.ScaledObject{}
	err := te.Client.Get(ctx, types.NamespacedName{Namespace: "demo2", Name: "y"}, got)
	assert.True(t, apierrors.IsNotFound(err))
}
```

> **Scope note:** this integration suite is a smoke harness. Full webhook-path E2E coverage lives in the lab verify script (Task 24), which runs against a real cluster with cert-manager + KEDA + KDW deployed. That's the one that closes the loop on:
> - CREATE rejection in `error` ns
> - CREATE allowed-with-warning in `warn` ns (`legacy-cpu`)
> - UPDATE additive-only behaviour
> - CM hot-reload severity flip + ghost series cleanup
> The envtest layer is kept lean because cert-manager and KEDA controller dependencies make full envtest setup brittle.

- [ ] **Step 4: Add CRDs to testdata**

```bash
mkdir -p test/testdata/crds
KEDA_DIR="$(go env GOMODCACHE)/github.com/kedacore/keda/v2@v2.16.1"
cp "${KEDA_DIR}/config/crd/bases/keda.sh_scaledobjects.yaml" test/testdata/crds/
cp "${KEDA_DIR}/config/crd/bases/keda.sh_scaledjobs.yaml" test/testdata/crds/
```

- [ ] **Step 5: Run integration tests**

```bash
go test -tags integration ./test/integration/... -v
```

Expected: PASS — both tests.

- [ ] **Step 6: Commit**

```bash
git add test/integration/ test/testdata/
git commit -m "test(kdw): envtest harness for CRD round-trip"
```

---

### Task 23: Install script

**Files:**
- Create: `scripts/install-webhook.sh`

- [ ] **Step 1: Write the script**

```bash
#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "${SCRIPT_DIR}/lib.sh"

ensure_cluster
require_cmd docker
require_cmd kubectl

KDW_NAMESPACE="${KDW_NAMESPACE:-keda-system}"
KDW_IMAGE="${KDW_IMAGE:-keda-deprecation-webhook:dev}"
MANIFEST_DIR="${ROOT_DIR}/manifests/keda-deprecation-webhook"

log "building keda-deprecation-webhook image: ${KDW_IMAGE}"
docker build -t "${KDW_IMAGE}" -f "${ROOT_DIR}/Dockerfile" "${ROOT_DIR}"

load_docker_image_to_kind "${KDW_IMAGE}"

# Manifests are applied in dependency order:
#   namespace → rbac → cert (waits for cert-manager) → cm → svc → deploy →
#   pdb → vwc.
# cert-manager itself is installed transitively by install-keda.sh and is
# expected to be ready before this script runs.
log "applying KDW manifests to ${KDW_NAMESPACE}"
kubectl apply -f "${MANIFEST_DIR}/namespace.yaml"
kubectl apply -f "${MANIFEST_DIR}/rbac.yaml"
kubectl apply -f "${MANIFEST_DIR}/certificate.yaml"

log "waiting for kdw-tls secret to be issued by cert-manager"
for _ in {1..60}; do
  if kubectl -n "${KDW_NAMESPACE}" get secret kdw-tls >/dev/null 2>&1; then
    break
  fi
  sleep 2
done
kubectl -n "${KDW_NAMESPACE}" get secret kdw-tls >/dev/null \
  || fail "cert-manager did not issue kdw-tls within 120s"

kubectl apply -f "${MANIFEST_DIR}/configmap.yaml"
kubectl apply -f "${MANIFEST_DIR}/service.yaml"
kubectl apply -f "${MANIFEST_DIR}/deployment.yaml"
kubectl apply -f "${MANIFEST_DIR}/pdb.yaml"
kubectl apply -f "${MANIFEST_DIR}/validatingwebhookconfiguration.yaml"

kubectl_wait_rollout "${KDW_NAMESPACE}" deployment/keda-deprecation-webhook
log "keda-deprecation-webhook is ready"
```

- [ ] **Step 2: Make executable**

```bash
chmod +x scripts/install-webhook.sh
```

- [ ] **Step 3: Commit**

```bash
git add scripts/install-webhook.sh
git commit -m "feat(kdw): install-webhook.sh"
```

---

### Task 24: Verify script (lab E2E)

**Files:**
- Create: `scripts/verify-webhook.sh`

- [ ] **Step 1: Write the script**

```bash
#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "${SCRIPT_DIR}/lib.sh"

ensure_cluster
require_cmd kubectl
require_cmd curl

KDW_NS="${KDW_NS:-keda-system}"
DEMO_NS="demo-deprecated"

# 1. Pod healthy
log "checking pod health"
kubectl -n "${KDW_NS}" rollout status deployment/keda-deprecation-webhook --timeout=60s

# 2. /metrics is reachable from inside the cluster
log "checking /metrics endpoint"
kubectl -n "${KDW_NS}" run kdw-curl --rm -it --image=curlimages/curl:8.10.1 \
  --restart=Never --quiet -- \
  curl -fsS http://keda-deprecation-webhook.${KDW_NS}.svc:8080/metrics > /tmp/kdw-metrics.txt
grep -q '^keda_deprecation_config_generation' /tmp/kdw-metrics.txt \
  || fail "config_generation metric missing"
log "metrics endpoint OK ($(wc -l </tmp/kdw-metrics.txt) lines)"

# 3. CREATE in demo-deprecated → expected REJECTION
log "applying demo-deprecated SO (expecting reject)"
kubectl apply -f "${ROOT_DIR}/manifests/demo-deprecated/namespace.yaml"
kubectl apply -f "${ROOT_DIR}/manifests/demo-deprecated/deployment.yaml"
set +e
APPLY_OUT="$(kubectl apply -f "${ROOT_DIR}/manifests/demo-deprecated/scaledobject.yaml" 2>&1)"
APPLY_RC=$?
set -e
echo "${APPLY_OUT}"
[[ ${APPLY_RC} -ne 0 ]] || fail "expected webhook rejection, but apply succeeded"
echo "${APPLY_OUT}" | grep -q "KEDA001" \
  || fail "expected KEDA001 in rejection message, got: ${APPLY_OUT}"
log "demo-deprecated SO correctly rejected"

# 4. legacy-cpu (warn ns) — should already exist with deprecated form,
#    expect violations gauge = 1 with severity=warn.
log "checking warn-mode gauge for legacy-cpu"
kubectl -n "${KDW_NS}" run kdw-curl --rm -it --image=curlimages/curl:8.10.1 \
  --restart=Never --quiet -- \
  curl -fsS "http://keda-deprecation-webhook.${KDW_NS}.svc:8080/metrics" \
  | grep 'keda_deprecation_violations{' \
  | grep 'namespace="legacy-cpu"' \
  | grep 'severity="warn"' \
  || fail "expected violations{namespace=legacy-cpu, severity=warn} not found"
log "warn-mode gauge OK"

# 5. CM hot-reload: flip legacy-cpu severity to off, expect old warn series gone.
log "hot-reloading CM to severity=off for legacy-cpu"
kubectl -n "${KDW_NS}" patch configmap keda-deprecation-webhook-config \
  --type merge -p "$(cat <<'EOF'
{"data":{"config.yaml":"rules:\n  - id: KEDA001\n    defaultSeverity: error\n    namespaceOverrides:\n      - names: [\"legacy-cpu\"]\n        severity: off\n"}}
EOF
)"

log "waiting up to 60s for warn series to disappear"
for _ in {1..30}; do
  out="$(kubectl -n "${KDW_NS}" run kdw-curl --rm -it --image=curlimages/curl:8.10.1 \
    --restart=Never --quiet -- \
    curl -fsS "http://keda-deprecation-webhook.${KDW_NS}.svc:8080/metrics" || true)"
  echo "${out}" | grep 'keda_deprecation_violations{' | grep 'namespace="legacy-cpu"' | grep 'severity="warn"' \
    || { log "warn series cleared, off series should now be present"; break; }
  sleep 2
done
echo "${out}" | grep 'keda_deprecation_violations{' | grep 'namespace="legacy-cpu"' | grep 'severity="off"' \
  || fail "expected severity=off series after reload, not seen in metrics"

# 6. Restore CM to warn mode for the rest of the lab session.
log "restoring CM"
kubectl apply -f "${ROOT_DIR}/manifests/keda-deprecation-webhook/configmap.yaml"

log "verify-webhook: all checks passed"
```

- [ ] **Step 2: Make executable**

```bash
chmod +x scripts/verify-webhook.sh
```

- [ ] **Step 3: Commit**

```bash
git add scripts/verify-webhook.sh
git commit -m "feat(kdw): verify-webhook.sh (lab E2E checks)"
```

---

### Task 25: Wire into Makefile + up.sh

**Files:**
- Modify: `Makefile`
- Modify: `scripts/up.sh`

- [ ] **Step 1: Add Makefile targets**

Edit `Makefile` — append new targets and update `.PHONY`:

```makefile
.PHONY: ... build-webhook install-webhook verify-webhook demo-deprecated
```

(Append the four target names to the existing `.PHONY` line at line 12-14.)

Append at the end of the file:

```makefile
build-webhook:
	@docker build -t keda-deprecation-webhook:dev -f Dockerfile .
	@CLUSTER_NAME=$(CLUSTER_NAME) ./scripts/install-webhook.sh

install-webhook:
	@CLUSTER_NAME=$(CLUSTER_NAME) ./scripts/install-webhook.sh

verify-webhook:
	@CLUSTER_NAME=$(CLUSTER_NAME) ./scripts/verify-webhook.sh

demo-deprecated:
	@kubectl apply -f manifests/demo-deprecated/namespace.yaml
	@kubectl apply -f manifests/demo-deprecated/deployment.yaml
	@kubectl apply -f manifests/demo-deprecated/scaledobject.yaml || true   # expected to be rejected
```

Also add a help line in the `help` target (around line 17-30):

```makefile
	@printf "  %-22s %s\n" "make verify-webhook" "Run keda-deprecation-webhook E2E checks"
	@printf "  %-22s %s\n" "make demo-deprecated" "Apply a deliberately-deprecated SO (expects rejection)"
```

- [ ] **Step 2: Update up.sh**

Edit `scripts/up.sh`. Insert `install-webhook.sh` after `install-keda.sh`:

```bash
#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

"${SCRIPT_DIR}/prereq-check.sh"
"${SCRIPT_DIR}/create-cluster.sh"
"${SCRIPT_DIR}/label-zones.sh"
"${SCRIPT_DIR}/prepull-images.sh"
"${SCRIPT_DIR}/install-monitoring.sh"
"${SCRIPT_DIR}/install-keda.sh"
"${SCRIPT_DIR}/install-webhook.sh"
"${SCRIPT_DIR}/deploy-demo.sh"
"${SCRIPT_DIR}/verify.sh"
```

- [ ] **Step 3: Smoke-test the targets exist**

```bash
make help | grep -E "(verify-webhook|demo-deprecated)"
```

Expected: both lines printed.

- [ ] **Step 4: Commit**

```bash
git add Makefile scripts/up.sh
git commit -m "feat(kdw): wire build/install/verify/demo into Makefile + up.sh"
```

---

### Task 26: Prometheus alert rules

**Files:**
- Modify: `prometheus/values.yaml`

- [ ] **Step 1: Locate the right insert point**

Run: `grep -n "name: keda-platform-slo" prometheus/values.yaml`

The new group `keda-deprecations` should sit at the same indent level as the existing `keda-platform-slo` group, inside `serverFiles.alerting_rules.yml.groups`.

- [ ] **Step 2: Append the new group**

Insert this block as a sibling group (same indentation) after the last existing alert group (look for the final `- alert:` block under any group), e.g. after the `DemoCpuPodsPending` alert:

```yaml
      - name: keda-deprecations
        interval: 30s
        rules:
          - alert: KedaDeprecationWebhookDown
            expr: up{job="kubernetes-service-endpoints", service="keda-deprecation-webhook"} == 0
            for: 5m
            labels:
              severity: critical
              component: keda-deprecation-webhook
            annotations:
              summary: keda-deprecation-webhook is unreachable
              description: |
                failurePolicy=Ignore — deprecated specs may slip through during this outage.
                Controller path will eventually surface them via keda_deprecation_violations.

          - alert: KedaDeprecationConfigReloadFailing
            expr: increase(keda_deprecation_config_reloads_total{result="error"}[10m]) > 0
            for: 0m
            labels:
              severity: warning
              component: keda-deprecation-webhook
            annotations:
              summary: keda-deprecation-webhook ConfigMap is invalid
              description: |
                Last good config still in use. Inspect events on the ConfigMap and fix.

          - alert: KedaDeprecationErrorViolationsPresent
            expr: sum(keda_deprecation_violations{severity="error"}) > 0
            for: 1h
            labels:
              severity: warning
              component: keda-deprecation-webhook
            annotations:
              summary: '{{ $value }} ScaledObject(s) still have severity=error deprecation violations'
              description: |
                These will break on KEDA 2.18. Review the KEDA Deprecations dashboard for the list.
```

- [ ] **Step 3: Verify YAML is valid**

```bash
yq '.serverFiles.alerting_rules.yml.groups | map(.name)' prometheus/values.yaml
```

Expected output includes `keda-deprecations`.

- [ ] **Step 4: Reapply Prometheus**

```bash
make install-prometheus
```

Wait for rollout, then verify the rules loaded:

```bash
kubectl -n monitoring port-forward svc/prometheus-server 9090:80 &
sleep 2
curl -fsS http://localhost:9090/api/v1/rules | jq '.data.groups[] | select(.name=="keda-deprecations") | .rules | length'
```

Expected: `3`.

- [ ] **Step 5: Commit**

```bash
git add prometheus/values.yaml
git commit -m "feat(prom): keda-deprecations alert group"
```

---

### Task 27: Grafana dashboard

**Files:**
- Create: `grafana/dashboards/keda-deprecations.json`
- Modify: dashboard provisioning ConfigMap (per project memory: edit JSON alone is not enough — must regenerate the `grafana-dashboards` CM and roll Grafana)

- [ ] **Step 1: Determine the dashboards CM regeneration path**

Inspect how existing dashboards are loaded:

```bash
ls scripts/install-grafana.sh
grep -n "dashboards" scripts/install-grafana.sh || true
grep -n "grafana-dashboards" manifests/ -r 2>/dev/null
```

Identify the script/manifest responsible for building the `grafana-dashboards` ConfigMap from the JSON files in `grafana/dashboards/`. The new dashboard must be picked up by the same mechanism.

- [ ] **Step 2: Author the dashboard JSON**

The dashboard MUST have:
- `uid`: `keda-deprecations`
- `title`: `KEDA Deprecations`
- Template variables (matching the two existing dashboards):
  - `Datasource` (datasource selector, default Prometheus)
  - `Prodsuite` (multi-value, label_values(kube_namespace_labels, label_prodsuite))
  - `Namespace` (multi-value, label_values(kube_namespace_status_phase{namespace=~"$Namespace"}, namespace) — match existing pattern)

Panels (in this order):

| # | Type | Title | Query |
|---|---|---|---|
| 1 | Stat | Error violations | `sum(keda_deprecation_violations{severity="error", namespace=~"$Namespace"})` |
| 2 | Stat | Warn violations | `sum(keda_deprecation_violations{severity="warn", namespace=~"$Namespace"})` |
| 3 | Stat | Off violations (exempted debt) | `sum(keda_deprecation_violations{severity="off", namespace=~"$Namespace"})` |
| 4 | Time series | Violations over time by severity | `sum by (severity) (keda_deprecation_violations{namespace=~"$Namespace"})` |
| 5 | Table | Per-violation detail | `keda_deprecation_violations{namespace=~"$Namespace"}` (Format=Table, Instant=true; transform to columns: namespace, kind, name, trigger_index, trigger_type, rule_id, severity) |
| 6 | Time series | Admission rejects (7d) | `sum by (namespace, rule_id) (rate(keda_deprecation_admission_rejects_total{namespace=~"$Namespace"}[5m]))` |
| 7 | Time series | Admission warnings (7d) | `sum by (namespace, rule_id) (rate(keda_deprecation_admission_warnings_total{namespace=~"$Namespace"}[5m]))` |
| 8 | Stat | Config generation | `keda_deprecation_config_generation` |
| 9 | Stat | Config reload errors (7d) | `increase(keda_deprecation_config_reloads_total{result="error"}[7d])` (red threshold > 0) |

Build the JSON one of two ways:
- **Authoring in Grafana UI:** port-forward Grafana, build the dashboard interactively, click "Save as JSON", commit the exported file.
- **Hand-write:** copy `grafana/dashboards/keda-operations.json` as a structural template, replace the panels, fix the UID and title.

- [ ] **Step 3: Regenerate the dashboards CM and roll Grafana**

Per the project memory: editing the JSON alone won't reach the running pod. Run the regeneration step (whatever `install-grafana.sh` does) and restart Grafana so it picks up the new dashboard.

```bash
make install-grafana   # or whichever target rebuilds the CM and rolls grafana
make grafana &         # port-forward
# Open http://localhost:3000 → look for "KEDA Deprecations" dashboard.
```

- [ ] **Step 4: Verify all 9 panels render with data after `make demo-deprecated`**

Apply the demo-deprecated SO to generate counter increments; refresh the dashboard; ensure non-zero rejects in panel 6.

- [ ] **Step 5: Commit**

```bash
git add grafana/dashboards/keda-deprecations.json
# Plus whatever provisioning files you regenerated:
git add scripts/install-grafana.sh manifests/.../grafana-dashboards-cm.yaml 2>/dev/null || true
git commit -m "feat(grafana): KEDA Deprecations dashboard"
```

---

### Task 28: Final E2E + README

**Files:**
- Modify: `README.md`

- [ ] **Step 1: Run full lab from scratch**

```bash
make recreate
```

Expected: succeeds, ending in `verify.sh` clean output. The webhook is up between KEDA install and demo deploy.

- [ ] **Step 2: Run webhook E2E**

```bash
make verify-webhook
```

Expected: all 6 checks pass; the script prints `verify-webhook: all checks passed`.

- [ ] **Step 3: Trigger reject demo**

```bash
make demo-deprecated
```

Expected: `kubectl apply` fails with a webhook rejection mentioning `KEDA001` and the `metricType: Utilization` fix hint. Counter `keda_deprecation_admission_rejects_total{namespace="demo-deprecated", rule_id="KEDA001", operation="CREATE"}` increments.

- [ ] **Step 4: Update README.md**

Add a new section (under the existing component list):

```markdown
## keda-deprecation-webhook (KDW)

A ValidatingWebhook + controller that blocks/inventories deprecated KEDA spec
fields ahead of the 2.16 → 2.18 fleet upgrade. KEDA001 (cpu/memory
`metadata.type`) is the first rule shipped.

- Spec: `docs/superpowers/specs/2026-05-05-keda-deprecation-webhook-design.md`
- Manifests: `manifests/keda-deprecation-webhook/`
- Lab CM exempts `legacy-cpu` to severity=warn (existing offender), and
  rejects new offenders by default (`make demo-deprecated`).
- Dashboard: Grafana → KEDA Deprecations.
- Verify: `make verify-webhook`.
```

- [ ] **Step 5: Commit**

```bash
git add README.md
git commit -m "docs(readme): mention keda-deprecation-webhook"
```

---

## Self-review notes

1. **Spec coverage:**
   - KEDA001 rule + framework — Tasks 2, 3.
   - Config schema, resolver, loader, store, watcher — Tasks 4–7, 12.
   - Webhook decision algorithm (CREATE strict, UPDATE additive-only) — Tasks 9, 10.
   - Controller reconcile loop (gauge label-set bookkeeping incl. severity flip cleanup) — Tasks 11, 15.
   - Namespace label watcher — Tasks 13, 14.
   - Metrics (gauge + counters + config_generation) — Task 8.
   - cert-manager Issuer + Certificate, VWC with cainjector annotation — Tasks 19, 20.
   - Deployment hygiene (2 replicas, PDB, probes, resource limits, Prometheus annotations) — Task 20.
   - Lab integration (Makefile, up.sh, demo workloads, install/verify scripts) — Tasks 21, 23, 24, 25.
   - Grafana dashboard + Prometheus alerts — Tasks 26, 27.
   - Multi-cluster rollout plan — out of scope for this plan (operational, not code).

2. **Type consistency:** `Severity` lives in `internal/rules`, imported by `internal/config` (no cycle). `metrics.ViolationLabels` is the gauge label schema, used by both webhook (indirectly via emitter on the controller side) and emitter directly. `controller.Emitter.Sync` accepts `[]metrics.ViolationLabels` — same type used by both reconcilers.

3. **Notable simplifications vs spec:**
   - Reuses existing `manifests/legacy-cpu/` as the warn-mode demo target. The spec's `demo-deprecated-warn/` directory is not created — collapsed into a CM `namespaceOverrides` entry on `legacy-cpu`.
   - cert-manager install is not added to `up.sh` because `install-keda.sh` already pulls it in.
   - Probe port is `:8081` so it doesn't collide with the metrics endpoint on `:8080`. Spec text mentioned both on `:8080` but probes need a separate port if metrics is served by a goroutine, not the manager.

4. **Open implementation choices left to the engineer:**
   - The exact `isNotFound` shim in `internal/config/watcher.go` — the plan suggests substituting `apierrors.IsNotFound(err)` for clarity.
   - Whether to use the manager's built-in metrics handler vs the inline goroutine. The plan goes with the goroutine for explicit control over the Registry.
   - The dashboard JSON — UI-export vs hand-write is the engineer's choice. Required panels and queries are pinned.

---

## Execution Handoff

Plan complete and saved to `docs/superpowers/plans/2026-05-09-keda-deprecation-webhook.md`. Two execution options:

**1. Subagent-Driven (recommended)** — fresh subagent per task, review between tasks, fast iteration.

**2. Inline Execution** — execute tasks in this session using executing-plans, batch execution with checkpoints.

Which approach?
