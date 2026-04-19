package main

import (
	"context"
	"os"
	"os/signal"
	"syscall"

	"k8s.io/klog/v2"
)

func main() {
	ctx, cancel := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer cancel()

	klog.Info("rpi5-dra-driver starting")
	<-ctx.Done()
	klog.Info("rpi5-dra-driver shutting down")
}
