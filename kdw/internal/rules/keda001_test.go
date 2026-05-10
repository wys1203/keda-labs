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
