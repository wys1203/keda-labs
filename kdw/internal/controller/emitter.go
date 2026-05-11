package controller

import (
	"sync"

	"k8s.io/apimachinery/pkg/types"

	"github.com/wys1203/keda-labs/kdw/internal/metrics"
)

// Emitter holds the source-of-truth for which gauge series are currently
// asserted, keyed by the owning object. It diffs the previous label set
// against the new one on each Sync so that severity flips, namespace label
// changes, and trigger edits all leave a consistent gauge state — no ghost
// series under prior severity labels.
type Emitter struct {
	mu      sync.Mutex
	last    map[types.NamespacedName][]metrics.ViolationLabels
	metrics *metrics.Metrics
}

func NewEmitter(m *metrics.Metrics) *Emitter {
	return &Emitter{
		last:    make(map[types.NamespacedName][]metrics.ViolationLabels),
		metrics: m,
	}
}

// Sync replaces the set of gauge series asserted for `obj` with `next`.
// Any label set previously emitted for `obj` that is not in `next` is
// deleted from the gauge before new ones are set. Order: delete first,
// set second, so transient `Set(0)` is never observable.
func (e *Emitter) Sync(obj types.NamespacedName, next []metrics.ViolationLabels) {
	e.mu.Lock()
	defer e.mu.Unlock()

	prev := e.last[obj]
	nextSet := indexLabels(next)

	for _, p := range prev {
		if _, keep := nextSet[labelKey(p)]; !keep {
			e.metrics.Violations.Delete(p.ToMap())
		}
	}
	for _, n := range next {
		e.metrics.Violations.With(n.ToMap()).Set(1)
	}
	if len(next) == 0 {
		delete(e.last, obj)
	} else {
		e.last[obj] = append([]metrics.ViolationLabels(nil), next...)
	}
}

// Forget drops every series for `obj`. Called on object delete.
func (e *Emitter) Forget(obj types.NamespacedName) {
	e.mu.Lock()
	defer e.mu.Unlock()
	for _, p := range e.last[obj] {
		e.metrics.Violations.Delete(p.ToMap())
	}
	delete(e.last, obj)
}

func indexLabels(s []metrics.ViolationLabels) map[string]struct{} {
	out := make(map[string]struct{}, len(s))
	for _, l := range s {
		out[labelKey(l)] = struct{}{}
	}
	return out
}

func labelKey(l metrics.ViolationLabels) string {
	return l.Namespace + "|" + l.Kind + "|" + l.Name + "|" +
		l.TriggerIndex + "|" + l.TriggerType + "|" + l.RuleID + "|" + l.Severity
}
