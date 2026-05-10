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
