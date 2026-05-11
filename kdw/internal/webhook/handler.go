package webhook

import (
	"context"
	"encoding/json"
	"fmt"
	"strings"

	admissionv1 "k8s.io/api/admission/v1"
	"sigs.k8s.io/controller-runtime/pkg/webhook/admission"

	kedav1alpha1 "github.com/kedacore/keda/v2/apis/keda/v1alpha1"

	"github.com/wys1203/keda-labs/kdw/internal/config"
	"github.com/wys1203/keda-labs/kdw/internal/metrics"
	"github.com/wys1203/keda-labs/kdw/internal/rules"
)

type NamespaceCache interface {
	Get(ns string) map[string]string
}

type Handler struct {
	Config  *config.Store
	NSCache NamespaceCache
	Metrics *metrics.Metrics
	MsgURL  string // optional internal runbook URL surfaced in rejection messages
}

func (h *Handler) Handle(_ context.Context, req admission.Request) admission.Response {
	cfg := h.Config.Load()
	nsLabels := h.NSCache.Get(req.Namespace)

	newT, err := decodeTarget(req.Object.Raw, req.Kind.Kind, req.Namespace)
	if err != nil {
		return admission.Errored(400, fmt.Errorf("decode new object: %w", err))
	}

	var oldT *rules.Target
	if req.Operation == admissionv1.Update && len(req.OldObject.Raw) > 0 {
		o, err := decodeTarget(req.OldObject.Raw, req.Kind.Kind, req.Namespace)
		if err != nil {
			return admission.Errored(400, fmt.Errorf("decode old object: %w", err))
		}
		oldT = &o
	}

	newV := rules.LintAll(newT)
	var oldV []rules.Violation
	if oldT != nil {
		oldV = rules.LintAll(*oldT)
	}

	candidates := newV
	if oldT != nil {
		candidates = DiffByKey(newV, oldV)
	}

	var rejecting []rules.Violation
	for _, v := range candidates {
		if cfg.EffectiveSeverity(v.RuleID, req.Namespace, nsLabels) == rules.SeverityError {
			rejecting = append(rejecting, v)
		}
	}
	if len(rejecting) > 0 {
		op := string(req.Operation)
		for _, v := range rejecting {
			h.Metrics.AdmissionRejects.WithLabelValues(req.Namespace, req.Kind.Kind, v.RuleID, op).Inc()
		}
		return admission.Denied(formatRejection(rejecting, h.MsgURL))
	}

	var warnings []string
	for _, v := range newV {
		sev := cfg.EffectiveSeverity(v.RuleID, req.Namespace, nsLabels)
		if sev == rules.SeverityOff {
			continue
		}
		warnings = append(warnings, formatWarning(v))
		h.Metrics.AdmissionWarnings.WithLabelValues(req.Namespace, req.Kind.Kind, v.RuleID).Inc()
	}
	resp := admission.Allowed("")
	resp.Warnings = warnings
	return resp
}

func decodeTarget(raw []byte, kind, ns string) (rules.Target, error) {
	switch kind {
	case "ScaledObject":
		var obj kedav1alpha1.ScaledObject
		if err := json.Unmarshal(raw, &obj); err != nil {
			return rules.Target{}, err
		}
		return rules.Target{Kind: kind, Namespace: obj.Namespace, Name: obj.Name, Triggers: obj.Spec.Triggers}, nil
	case "ScaledJob":
		var obj kedav1alpha1.ScaledJob
		if err := json.Unmarshal(raw, &obj); err != nil {
			return rules.Target{}, err
		}
		return rules.Target{Kind: kind, Namespace: obj.Namespace, Name: obj.Name, Triggers: obj.Spec.Triggers}, nil
	default:
		return rules.Target{}, fmt.Errorf("unsupported kind %q", kind)
	}
}

func formatRejection(vs []rules.Violation, msgURL string) string {
	var sb strings.Builder
	sb.WriteString("rejected by keda-deprecation-webhook:\n")
	for _, v := range vs {
		fmt.Fprintf(&sb, "  - [%s] %s — %s\n", v.RuleID, v.Message, v.FixHint)
	}
	if msgURL != "" {
		fmt.Fprintf(&sb, "see %s for migration guidance.\n", msgURL)
	}
	return sb.String()
}

func formatWarning(v rules.Violation) string {
	return fmt.Sprintf("[%s] %s — %s", v.RuleID, v.Message, v.FixHint)
}
