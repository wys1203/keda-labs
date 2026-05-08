package controller

import (
	"context"
	"strconv"

	apierrors "k8s.io/apimachinery/pkg/api/errors"
	ctrl "sigs.k8s.io/controller-runtime"
	"sigs.k8s.io/controller-runtime/pkg/client"
	"sigs.k8s.io/controller-runtime/pkg/event"
	"sigs.k8s.io/controller-runtime/pkg/handler"
	"sigs.k8s.io/controller-runtime/pkg/reconcile"
	"sigs.k8s.io/controller-runtime/pkg/source"

	kedav1alpha1 "github.com/kedacore/keda/v2/apis/keda/v1alpha1"

	"github.com/wys1203/keda-labs/internal/config"
	"github.com/wys1203/keda-labs/internal/metrics"
	"github.com/wys1203/keda-labs/internal/rules"
)

type ScaledObjectReconciler struct {
	Client   client.Client
	Config   *config.Store
	Cache    *NamespaceCache
	Emitter  *Emitter
	ExtraSrc <-chan event.GenericEvent
}

func (r *ScaledObjectReconciler) SetupWithManager(mgr ctrl.Manager) error {
	c := ctrl.NewControllerManagedBy(mgr).For(&kedav1alpha1.ScaledObject{})
	if r.ExtraSrc != nil {
		c = c.WatchesRawSource(source.Channel(r.ExtraSrc, &handler.EnqueueRequestForObject{}))
	}
	return c.Complete(r)
}

func (r *ScaledObjectReconciler) Reconcile(ctx context.Context, req reconcile.Request) (reconcile.Result, error) {
	var so kedav1alpha1.ScaledObject
	if err := r.Client.Get(ctx, req.NamespacedName, &so); err != nil {
		if apierrors.IsNotFound(err) {
			r.Emitter.Forget(req.NamespacedName)
			return reconcile.Result{}, nil
		}
		return reconcile.Result{}, err
	}
	target := rules.Target{
		Kind: "ScaledObject", Namespace: so.Namespace, Name: so.Name, Triggers: so.Spec.Triggers,
	}
	r.Emitter.Sync(req.NamespacedName, r.violationsToLabels(target))
	return reconcile.Result{}, nil
}

func (r *ScaledObjectReconciler) violationsToLabels(t rules.Target) []metrics.ViolationLabels {
	cfg := r.Config.Load()
	nsLabels := r.Cache.Get(t.Namespace)
	vs := rules.LintAll(t)
	out := make([]metrics.ViolationLabels, 0, len(vs))
	for _, v := range vs {
		sev := cfg.EffectiveSeverity(v.RuleID, t.Namespace, nsLabels)
		out = append(out, metrics.ViolationLabels{
			Namespace: t.Namespace, Kind: t.Kind, Name: t.Name,
			TriggerIndex: strconv.Itoa(v.TriggerIndex),
			TriggerType:  v.TriggerType, RuleID: v.RuleID,
			Severity: string(sev),
		})
	}
	return out
}
