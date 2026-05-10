package config

import (
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
	"github.com/wys1203/keda-labs/kdw/internal/rules"
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
        severity: "off"
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
