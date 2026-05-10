package metrics

import (
	"strings"
	"testing"

	"github.com/prometheus/client_golang/prometheus/testutil"
	"github.com/stretchr/testify/assert"
)

func TestNew_RegistersAllCollectors(t *testing.T) {
	m := New()
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

func dumpMetricNames(t *testing.T, m *Metrics) string {
	t.Helper()
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
