package config

import (
	"context"
	"fmt"

	corev1 "k8s.io/api/core/v1"
	apierrors "k8s.io/apimachinery/pkg/api/errors"
	"k8s.io/apimachinery/pkg/types"
	ctrl "sigs.k8s.io/controller-runtime"
	"sigs.k8s.io/controller-runtime/pkg/builder"
	"sigs.k8s.io/controller-runtime/pkg/client"
	"sigs.k8s.io/controller-runtime/pkg/log"
	"sigs.k8s.io/controller-runtime/pkg/predicate"
	"sigs.k8s.io/controller-runtime/pkg/reconcile"

	"github.com/wys1203/keda-labs/internal/metrics"
)

// ReEnqueueAll is called after a successful CM reload so that all
// watched SOs/SJs are re-linted with the new config (their gauge severity
// labels need to flip immediately, not on the next informer event).
type ReEnqueueAll func(context.Context)

// EventRecorder is the slice of record.EventRecorder we use here. Defined
// as an interface to avoid pulling client-go's event sink into tests.
type EventRecorder interface {
	Eventf(object client.Object, eventType, reason, messageFmt string, args ...interface{})
}

type Watcher struct {
	Client       client.Client
	Namespace    string
	Name         string
	Store        *Store
	Metrics      *metrics.Metrics
	ReEnqueueAll ReEnqueueAll
	Recorder     EventRecorder
}

func (w *Watcher) SetupWithManager(mgr ctrl.Manager) error {
	pred := predicate.NewPredicateFuncs(func(obj client.Object) bool {
		return obj.GetNamespace() == w.Namespace && obj.GetName() == w.Name
	})
	return ctrl.NewControllerManagedBy(mgr).
		For(&corev1.ConfigMap{}, builder.WithPredicates(pred)).
		Complete(w)
}

func (w *Watcher) Reconcile(ctx context.Context, req reconcile.Request) (reconcile.Result, error) {
	logger := log.FromContext(ctx).WithValues("configmap", req.NamespacedName)

	var cm corev1.ConfigMap
	if err := w.Client.Get(ctx, req.NamespacedName, &cm); err != nil {
		if apierrors.IsNotFound(err) {
			logger.Info("config map not found; falling back to empty config (built-in defaults)")
			w.Store.Store(&Config{})
			return reconcile.Result{}, nil
		}
		return reconcile.Result{}, err
	}

	raw, ok := cm.Data["config.yaml"]
	if !ok {
		err := fmt.Errorf("config.yaml key missing")
		w.handleErr(ctx, &cm, err)
		return reconcile.Result{}, nil
	}

	cfg, err := ParseYAML([]byte(raw))
	if err != nil {
		w.handleErr(ctx, &cm, err)
		return reconcile.Result{}, nil
	}

	w.Store.Store(cfg)
	w.Metrics.ConfigReloads.WithLabelValues("success").Inc()
	w.Metrics.ConfigGeneration.Set(float64(w.Store.Generation()))
	logger.Info("config reloaded", "generation", w.Store.Generation())
	if w.ReEnqueueAll != nil {
		w.ReEnqueueAll(ctx)
	}
	return reconcile.Result{}, nil
}

func (w *Watcher) handleErr(ctx context.Context, cm *corev1.ConfigMap, err error) {
	logger := log.FromContext(ctx)
	logger.Error(err, "config reload failed; keeping last good config")
	w.Metrics.ConfigReloads.WithLabelValues("error").Inc()
	if w.Recorder != nil {
		w.Recorder.Eventf(cm, corev1.EventTypeWarning, "InvalidConfig", "config reload failed: %v", err)
	}
}

// NamespacedName re-export so callers can construct selectors
// without importing apimachinery explicitly.
type NamespacedName = types.NamespacedName
