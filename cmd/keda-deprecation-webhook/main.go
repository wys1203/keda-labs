// cmd/keda-deprecation-webhook/main.go
package main

import (
	"flag"
	"fmt"
	"net/http"
	"os"

	"go.uber.org/zap/zapcore"
	corev1 "k8s.io/api/core/v1"
	"k8s.io/apimachinery/pkg/runtime"
	utilruntime "k8s.io/apimachinery/pkg/util/runtime"
	clientgoscheme "k8s.io/client-go/kubernetes/scheme"
	ctrl "sigs.k8s.io/controller-runtime"
	"sigs.k8s.io/controller-runtime/pkg/cache"
	"sigs.k8s.io/controller-runtime/pkg/client"
	"sigs.k8s.io/controller-runtime/pkg/healthz"
	"sigs.k8s.io/controller-runtime/pkg/log/zap"
	"sigs.k8s.io/controller-runtime/pkg/manager"
	metricsserver "sigs.k8s.io/controller-runtime/pkg/metrics/server"
	"sigs.k8s.io/controller-runtime/pkg/webhook"

	"github.com/prometheus/client_golang/prometheus/promhttp"

	kedav1alpha1 "github.com/kedacore/keda/v2/apis/keda/v1alpha1"

	"github.com/wys1203/keda-labs/internal/config"
	"github.com/wys1203/keda-labs/internal/controller"
	"github.com/wys1203/keda-labs/internal/metrics"
	whk "github.com/wys1203/keda-labs/internal/webhook"
)

var scheme = runtime.NewScheme()

func init() {
	utilruntime.Must(clientgoscheme.AddToScheme(scheme))
	utilruntime.Must(kedav1alpha1.AddToScheme(scheme))
	utilruntime.Must(corev1.AddToScheme(scheme))
}

func main() {
	var (
		metricsAddr = flag.String("metrics-bind-address", ":8080", "Address to serve Prometheus metrics on.")
		probeAddr   = flag.String("health-probe-bind-address", ":8081", "Address for health/readyz probes.")
		webhookPort = flag.Int("webhook-port", 9443, "Port for the admission webhook server.")
		certDir     = flag.String("cert-dir", "/etc/webhook/certs", "Directory containing TLS certs for the webhook server.")
		cmName      = flag.String("config-map-name", "keda-deprecation-webhook-config", "Name of the ConfigMap holding webhook config.")
		msgURL      = flag.String("reject-message-url", os.Getenv("REJECT_MESSAGE_URL"), "Optional runbook URL appended to rejection messages.")
		leaderElect = flag.Bool("leader-elect", true, "Enable leader election.")
	)
	flag.Parse()
	ctrl.SetLogger(zap.New(zap.UseDevMode(false), zap.Level(zapcore.InfoLevel)))

	ns := os.Getenv("NAMESPACE")
	if ns == "" {
		ctrl.Log.Error(nil, "NAMESPACE env var unset")
		os.Exit(2)
	}

	mgr, err := ctrl.NewManager(ctrl.GetConfigOrDie(), manager.Options{
		Scheme:                  scheme,
		HealthProbeBindAddress:  *probeAddr,
		LeaderElection:          *leaderElect,
		LeaderElectionID:        "keda-deprecation-webhook.keda.sh",
		LeaderElectionNamespace: ns,
		// Disable the built-in metrics server; we serve /metrics ourselves in a
		// goroutine so we can attach our private prometheus.Registry.
		Metrics: metricsserver.Options{BindAddress: "0"},
		WebhookServer: webhook.NewServer(webhook.Options{
			Port:    *webhookPort,
			CertDir: *certDir,
		}),
		// Restrict ConfigMap watches to the webhook's own namespace to avoid
		// cluster-wide LIST which the namespace-scoped Role cannot authorize.
		Cache: cache.Options{
			ByObject: map[client.Object]cache.ByObject{
				&corev1.ConfigMap{}: {
					Namespaces: map[string]cache.Config{ns: {}},
				},
			},
		},
	})
	if err != nil {
		ctrl.Log.Error(err, "manager init failed")
		os.Exit(1)
	}

	m := metrics.New()
	store := config.NewStore()
	nsCache := controller.NewNamespaceCache()
	emitter := controller.NewEmitter(m)
	fanOut := controller.NewFanOut(mgr.GetClient())

	mgr.GetWebhookServer().Register(
		"/validate-keda-sh-v1alpha1",
		&webhook.Admission{Handler: &whk.Handler{
			Config: store, NSCache: nsCache, Metrics: m, MsgURL: *msgURL,
		}},
	)

	if err := (&config.Watcher{
		Client: mgr.GetClient(), Namespace: ns, Name: *cmName,
		Store: store, Metrics: m,
		ReEnqueueAll: fanOut.EnqueueAll,
	}).SetupWithManager(mgr); err != nil {
		ctrl.Log.Error(err, "config watcher setup failed")
		os.Exit(1)
	}

	if err := (&controller.NamespaceReconciler{
		Client: mgr.GetClient(), Cache: nsCache, Enq: fanOut,
	}).SetupWithManager(mgr); err != nil {
		ctrl.Log.Error(err, "ns reconciler setup failed")
		os.Exit(1)
	}

	if err := (&controller.ScaledObjectReconciler{
		Client: mgr.GetClient(), Config: store, Cache: nsCache, Emitter: emitter, ExtraSrc: fanOut.SOChan(),
	}).SetupWithManager(mgr); err != nil {
		ctrl.Log.Error(err, "SO reconciler setup failed")
		os.Exit(1)
	}

	if err := (&controller.ScaledJobReconciler{
		Client: mgr.GetClient(), Config: store, Cache: nsCache, Emitter: emitter, ExtraSrc: fanOut.SJChan(),
	}).SetupWithManager(mgr); err != nil {
		ctrl.Log.Error(err, "SJ reconciler setup failed")
		os.Exit(1)
	}

	if err := mgr.AddHealthzCheck("healthz", healthz.Ping); err != nil {
		ctrl.Log.Error(err, "healthz setup")
		os.Exit(1)
	}
	if err := mgr.AddReadyzCheck("readyz", func(_ *http.Request) error {
		if store.Generation() == 0 {
			return fmt.Errorf("config not yet loaded")
		}
		return nil
	}); err != nil {
		ctrl.Log.Error(err, "readyz setup")
		os.Exit(1)
	}

	go func() {
		mux := http.NewServeMux()
		mux.Handle("/metrics", promhttp.HandlerFor(m.Registry, promhttp.HandlerOpts{}))
		_ = http.ListenAndServe(*metricsAddr, mux)
	}()

	ctrl.Log.Info("starting manager", "namespace", ns)
	if err := mgr.Start(ctrl.SetupSignalHandler()); err != nil {
		ctrl.Log.Error(err, "manager exited")
		os.Exit(1)
	}
}
