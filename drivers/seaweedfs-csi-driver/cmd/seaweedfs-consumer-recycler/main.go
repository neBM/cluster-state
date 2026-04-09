package main

import (
	"context"
	"flag"
	"fmt"
	"os"
	"time"

	corev1 "k8s.io/api/core/v1"
	"k8s.io/apimachinery/pkg/fields"
	"k8s.io/client-go/kubernetes"
	typedcorev1 "k8s.io/client-go/kubernetes/typed/core/v1"
	"k8s.io/client-go/tools/record"
	ctrl "sigs.k8s.io/controller-runtime"
	"sigs.k8s.io/controller-runtime/pkg/cache"
	"sigs.k8s.io/controller-runtime/pkg/client"
	"sigs.k8s.io/controller-runtime/pkg/healthz"
	ctrllog "sigs.k8s.io/controller-runtime/pkg/log"
	"sigs.k8s.io/controller-runtime/pkg/log/zap"
	"sigs.k8s.io/controller-runtime/pkg/manager"
	metricsserver "sigs.k8s.io/controller-runtime/pkg/metrics/server"

	"github.com/seaweedfs/seaweedfs-csi-driver/pkg/recycler"
)

const (
	driverName       = "seaweedfs-csi-driver"
	coldStartGrace   = 60 * time.Second
	probeInterval    = 30 * time.Second
	statTimeout      = 2 * time.Second
	stagger          = 5 * time.Second
	debounceTTL      = 120 * time.Second
	evictionRetry    = 5 * time.Second
	evictionDeadline = 30 * time.Second
)

func main() {
	var metricsAddr string
	var probeAddr string
	var procRoot string
	var statPath string

	flag.StringVar(&metricsAddr, "metrics-bind-address", ":9090", "Address for the metrics server.")
	flag.StringVar(&probeAddr, "health-probe-bind-address", ":9808", "Address for the health probe server.")
	flag.StringVar(&procRoot, "proc-root", "/host/proc", "Host /proc mount path.")
	flag.StringVar(&statPath, "stat-path", "/usr/bin/stat", "Path to the stat binary.")
	flag.Parse()

	nodeName := os.Getenv("NODE_NAME")
	if nodeName == "" {
		fmt.Fprintln(os.Stderr, "NODE_NAME environment variable is required")
		os.Exit(1)
	}

	opts := zap.Options{Development: false}
	opts.BindFlags(flag.CommandLine)
	ctrllog.SetLogger(zap.New(zap.UseFlagOptions(&opts)))
	logger := ctrllog.Log.WithName("seaweedfs-consumer-recycler")

	cfg, err := ctrl.GetConfig()
	if err != nil {
		logger.Error(err, "unable to get kubeconfig")
		os.Exit(1)
	}

	mgr, err := ctrl.NewManager(cfg, manager.Options{
		LeaderElection: false,
		Metrics: metricsserver.Options{
			BindAddress: metricsAddr,
		},
		HealthProbeBindAddress: probeAddr,
		Cache: cache.Options{
			ByObject: map[client.Object]cache.ByObject{
				&corev1.Pod{}: {
					Field: fields.OneTermEqualSelector("spec.nodeName", nodeName),
				},
			},
		},
	})
	if err != nil {
		logger.Error(err, "unable to create manager")
		os.Exit(1)
	}

	if err := mgr.AddHealthzCheck("ping", healthz.Ping); err != nil {
		logger.Error(err, "unable to add healthz check")
		os.Exit(1)
	}
	if err := mgr.AddReadyzCheck("ping", healthz.Ping); err != nil {
		logger.Error(err, "unable to add readyz check")
		os.Exit(1)
	}

	clientset, err := kubernetes.NewForConfig(cfg)
	if err != nil {
		logger.Error(err, "unable to create clientset")
		os.Exit(1)
	}

	broadcaster := record.NewBroadcaster()
	broadcaster.StartRecordingToSink(&typedcorev1.EventSinkImpl{Interface: clientset.CoreV1().Events("")})
	recorder := broadcaster.NewRecorder(mgr.GetScheme(), corev1.EventSource{Component: "seaweedfs-consumer-recycler"})

	evictor := &recycler.KubeEvictor{Clientset: clientset}
	debouncer := recycler.NewDebouncer(debounceTTL)
	cycler := &recycler.Cycler{
		Evictor:          evictor,
		Debounce:         debouncer,
		Stagger:          stagger,
		EvictionRetry:    evictionRetry,
		EvictionDeadline: evictionDeadline,
	}
	lookup := &recycler.PVLookup{
		Client:   mgr.GetClient(),
		NodeName: nodeName,
		Driver:   driverName,
	}
	rec := &recycler.Reconciler{
		Client:    mgr.GetClient(),
		NodeName:  nodeName,
		Lookup:    lookup,
		Cycler:    cycler,
		Baseline:  recycler.NewBaselineTracker(),
		ColdStart: recycler.NewColdStartWindow(coldStartGrace),
		Recorder:  recorder,
		Log:       logger,
	}

	if err := setupMountDaemonWatch(mgr, nodeName, rec); err != nil {
		logger.Error(err, "unable to set up mount daemon watch")
		os.Exit(1)
	}

	prober := &recycler.Prober{
		ProcRoot:    procRoot,
		StatPath:    statPath,
		StatTimeout: statTimeout,
		Interval:    probeInterval,
		Trigger:     rec.HandleProbeFailure,
	}
	if err := mgr.Add(manager.RunnableFunc(func(ctx context.Context) error {
		prober.Run(ctx)
		return nil
	})); err != nil {
		logger.Error(err, "unable to add prober runnable")
		os.Exit(1)
	}

	logger.Info("starting manager", "node", nodeName)
	if err := mgr.Start(ctrl.SetupSignalHandler()); err != nil {
		logger.Error(err, "manager exited with error")
		os.Exit(1)
	}
}
