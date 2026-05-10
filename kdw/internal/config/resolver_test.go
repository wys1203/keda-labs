package config

import (
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/wys1203/keda-labs/kdw/internal/rules"
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
