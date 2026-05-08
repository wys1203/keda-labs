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
