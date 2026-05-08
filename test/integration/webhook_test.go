//go:build integration

package integration

import (
	"context"
	"testing"
	"time"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
	apierrors "k8s.io/apimachinery/pkg/api/errors"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/types"

	kedav1alpha1 "github.com/kedacore/keda/v2/apis/keda/v1alpha1"
)

func TestEnvtest_AppliesScaledObject(t *testing.T) {
	te := StartEnv(t)
	mustCreateNamespace(t, te.Client, "demo", nil)

	so := &kedav1alpha1.ScaledObject{
		ObjectMeta: metav1.ObjectMeta{Name: "x", Namespace: "demo"},
		Spec: kedav1alpha1.ScaledObjectSpec{
			ScaleTargetRef: &kedav1alpha1.ScaleTarget{Name: "x"},
			Triggers: []kedav1alpha1.ScaleTriggers{
				{
					Type:       "cpu",
					MetricType: "Utilization",
					Metadata:   map[string]string{"value": "50"},
				},
			},
		},
	}
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	require.NoError(t, te.Client.Create(ctx, so))

	got := &kedav1alpha1.ScaledObject{}
	require.NoError(t, te.Client.Get(ctx, types.NamespacedName{Namespace: "demo", Name: "x"}, got))
	assert.Equal(t, "cpu", got.Spec.Triggers[0].Type)
}

func TestEnvtest_DeleteCleanly(t *testing.T) {
	te := StartEnv(t)
	mustCreateNamespace(t, te.Client, "demo2", nil)

	so := &kedav1alpha1.ScaledObject{
		ObjectMeta: metav1.ObjectMeta{Name: "y", Namespace: "demo2"},
		Spec: kedav1alpha1.ScaledObjectSpec{
			ScaleTargetRef: &kedav1alpha1.ScaleTarget{Name: "y"},
			Triggers: []kedav1alpha1.ScaleTriggers{
				{
					Type:     "cron",
					Metadata: map[string]string{"timezone": "UTC", "start": "0 6 * * *", "end": "0 20 * * *", "desiredReplicas": "5"},
				},
			},
		},
	}
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	require.NoError(t, te.Client.Create(ctx, so))
	require.NoError(t, te.Client.Delete(ctx, so))

	got := &kedav1alpha1.ScaledObject{}
	err := te.Client.Get(ctx, types.NamespacedName{Namespace: "demo2", Name: "y"}, got)
	assert.True(t, apierrors.IsNotFound(err))
}
