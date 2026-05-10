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

	"github.com/wys1203/keda-labs/kdw/internal/config"
	"github.com/wys1203/keda-labs/kdw/internal/metrics"
	"github.com/wys1203/keda-labs/kdw/internal/rules"
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
		Config:  store,
		NSCache: &fakeNSCache{},
		Metrics: metrics.New(),
		MsgURL:  "https://wiki.example/migrations/keda-2.18",
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
