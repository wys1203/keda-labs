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
