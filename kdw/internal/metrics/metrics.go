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

// ViolationLabels mirrors the gauge's label schema. Use ToMap() to feed
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
