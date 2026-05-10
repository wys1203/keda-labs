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
