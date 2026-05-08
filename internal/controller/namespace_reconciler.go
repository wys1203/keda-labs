package controller

import (
	"context"

	corev1 "k8s.io/api/core/v1"
	ctrl "sigs.k8s.io/controller-runtime"
	"sigs.k8s.io/controller-runtime/pkg/client"
	"sigs.k8s.io/controller-runtime/pkg/log"
	"sigs.k8s.io/controller-runtime/pkg/reconcile"

	kedav1alpha1 "github.com/kedacore/keda/v2/apis/keda/v1alpha1"
)

// NamespaceReconciler keeps NamespaceCache in sync and triggers a re-lint
// of every SO/SJ in the namespace whenever its labels change. (Add/remove
// of a `tier=legacy`-style override label must flip gauge severity for
// every affected object within one reconcile cycle, not at next event.)
type NamespaceReconciler struct {
	Client client.Client
	Cache  *NamespaceCache
	Enq    Enqueuer
}

// Enqueuer triggers reconciliation of all SOs/SJs in a namespace.
type Enqueuer interface {
	EnqueueAllInNamespace(ctx context.Context, ns string)
}

func (r *NamespaceReconciler) SetupWithManager(mgr ctrl.Manager) error {
	return ctrl.NewControllerManagedBy(mgr).
		For(&corev1.Namespace{}).
		Complete(r)
}

func (r *NamespaceReconciler) Reconcile(ctx context.Context, req reconcile.Request) (reconcile.Result, error) {
	logger := log.FromContext(ctx)

	var ns corev1.Namespace
	if err := r.Client.Get(ctx, req.NamespacedName, &ns); err != nil {
		// On delete, drop cache entry; SO/SJ in that ns will also be torn
		// down by k8s, which fires Delete events the SO/SJ reconciler handles.
		r.Cache.Delete(req.Name)
		return reconcile.Result{}, client.IgnoreNotFound(err)
	}

	r.Cache.Put(ns.Name, ns.Labels)
	logger.V(1).Info("namespace cache updated", "ns", ns.Name)

	if r.Enq != nil {
		r.Enq.EnqueueAllInNamespace(ctx, ns.Name)
	}
	return reconcile.Result{}, nil
}

// ListAllInNamespace is a convenience helper for callers that need to
// know what SO/SJ exist in a given namespace.
func ListAllInNamespace(ctx context.Context, c client.Client, ns string) ([]client.Object, error) {
	var sos kedav1alpha1.ScaledObjectList
	if err := c.List(ctx, &sos, client.InNamespace(ns)); err != nil {
		return nil, err
	}
	var sjs kedav1alpha1.ScaledJobList
	if err := c.List(ctx, &sjs, client.InNamespace(ns)); err != nil {
		return nil, err
	}
	out := make([]client.Object, 0, len(sos.Items)+len(sjs.Items))
	for i := range sos.Items {
		out = append(out, &sos.Items[i])
	}
	for i := range sjs.Items {
		out = append(out, &sjs.Items[i])
	}
	return out, nil
}
