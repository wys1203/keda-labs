//go:build integration

package integration

import (
	"context"
	"path/filepath"
	"testing"

	"github.com/stretchr/testify/require"
	corev1 "k8s.io/api/core/v1"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/runtime"
	clientgoscheme "k8s.io/client-go/kubernetes/scheme"
	"sigs.k8s.io/controller-runtime/pkg/client"
	"sigs.k8s.io/controller-runtime/pkg/envtest"
	logf "sigs.k8s.io/controller-runtime/pkg/log"
	"sigs.k8s.io/controller-runtime/pkg/log/zap"

	kedav1alpha1 "github.com/kedacore/keda/v2/apis/keda/v1alpha1"
)

// TestEnv holds the envtest environment and a ready-to-use client.
type TestEnv struct {
	Env    *envtest.Environment
	Client client.Client
}

// StartEnv starts an envtest environment with the KEDA CRDs loaded and
// registers a cleanup hook to stop it when the test finishes.
func StartEnv(t *testing.T) *TestEnv {
	t.Helper()
	logf.SetLogger(zap.New(zap.UseDevMode(true)))

	scheme := runtime.NewScheme()
	require.NoError(t, clientgoscheme.AddToScheme(scheme))
	require.NoError(t, corev1.AddToScheme(scheme))
	require.NoError(t, kedav1alpha1.AddToScheme(scheme))

	env := &envtest.Environment{
		CRDDirectoryPaths: []string{
			filepath.Join("..", "..", "test", "testdata", "crds"),
		},
		ErrorIfCRDPathMissing: true,
	}
	cfg, err := env.Start()
	require.NoError(t, err)

	c, err := client.New(cfg, client.Options{Scheme: scheme})
	require.NoError(t, err)

	t.Cleanup(func() {
		_ = env.Stop()
	})
	return &TestEnv{Env: env, Client: c}
}

func mustCreateNamespace(t *testing.T, c client.Client, name string, labels map[string]string) {
	t.Helper()
	obj := &corev1.Namespace{
		ObjectMeta: metav1.ObjectMeta{Name: name, Labels: labels},
	}
	require.NoError(t, c.Create(context.Background(), obj))
}
