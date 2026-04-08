package main

import (
	"context"

	corev1 "k8s.io/api/core/v1"
	ctrl "sigs.k8s.io/controller-runtime"
	"sigs.k8s.io/controller-runtime/pkg/builder"
	"sigs.k8s.io/controller-runtime/pkg/client"
	"sigs.k8s.io/controller-runtime/pkg/predicate"
	"sigs.k8s.io/controller-runtime/pkg/reconcile"

	"github.com/seaweedfs/seaweedfs-csi-driver/pkg/recycler"
)

func setupMountDaemonWatch(mgr ctrl.Manager, nodeName string, r *recycler.Reconciler) error {
	pred := predicate.NewPredicateFuncs(func(obj client.Object) bool {
		p, ok := obj.(*corev1.Pod)
		if !ok {
			return false
		}
		return p.Spec.NodeName == nodeName && p.Labels["component"] == "seaweedfs-mount"
	})

	return ctrl.NewControllerManagedBy(mgr).
		Named("seaweedfs-mount-watcher").
		For(&corev1.Pod{}, builder.WithPredicates(pred)).
		Complete(reconcile.Func(func(ctx context.Context, req reconcile.Request) (reconcile.Result, error) {
			var pod corev1.Pod
			if err := mgr.GetClient().Get(ctx, req.NamespacedName, &pod); err != nil {
				return reconcile.Result{}, client.IgnoreNotFound(err)
			}
			r.HandleMountDaemonEvent(ctx, &pod)
			return reconcile.Result{}, nil
		}))
}
