package controller

import (
	"context"

	"k8s.io/apimachinery/pkg/types"
	"sigs.k8s.io/controller-runtime/pkg/client"
	"sigs.k8s.io/controller-runtime/pkg/event"

	kedav1alpha1 "github.com/kedacore/keda/v2/apis/keda/v1alpha1"
)

// FanOut owns the controller-runtime Source channels for SO and SJ
// reconcilers. EnqueueAllInNamespace and EnqueueAll synthesize events
// onto those channels so the same workqueue path handles them.
type FanOut struct {
	soC chan event.GenericEvent
	sjC chan event.GenericEvent
	c   client.Client
}

func NewFanOut(c client.Client) *FanOut {
	return &FanOut{
		c:   c,
		soC: make(chan event.GenericEvent, 1024),
		sjC: make(chan event.GenericEvent, 1024),
	}
}

func (f *FanOut) SOChan() <-chan event.GenericEvent { return f.soC }
func (f *FanOut) SJChan() <-chan event.GenericEvent { return f.sjC }

func (f *FanOut) EnqueueAllInNamespace(ctx context.Context, ns string) {
	var sos kedav1alpha1.ScaledObjectList
	if err := f.c.List(ctx, &sos, client.InNamespace(ns)); err == nil {
		for i := range sos.Items {
			f.soC <- event.GenericEvent{Object: &sos.Items[i]}
		}
	}
	var sjs kedav1alpha1.ScaledJobList
	if err := f.c.List(ctx, &sjs, client.InNamespace(ns)); err == nil {
		for i := range sjs.Items {
			f.sjC <- event.GenericEvent{Object: &sjs.Items[i]}
		}
	}
}

func (f *FanOut) EnqueueAll(ctx context.Context) {
	var sos kedav1alpha1.ScaledObjectList
	if err := f.c.List(ctx, &sos); err == nil {
		for i := range sos.Items {
			f.soC <- event.GenericEvent{Object: &sos.Items[i]}
		}
	}
	var sjs kedav1alpha1.ScaledJobList
	if err := f.c.List(ctx, &sjs); err == nil {
		for i := range sjs.Items {
			f.sjC <- event.GenericEvent{Object: &sjs.Items[i]}
		}
	}
}

// keyOf is a small helper for tests / consumers that want a NamespacedName.
func keyOf(o client.Object) types.NamespacedName {
	return types.NamespacedName{Namespace: o.GetNamespace(), Name: o.GetName()}
}
