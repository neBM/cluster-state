package main

import (
	"context"
	"os"
	"os/signal"
	"syscall"

	"k8s.io/client-go/kubernetes"
	"k8s.io/client-go/rest"
	"k8s.io/dynamic-resource-allocation/kubeletplugin"
	"k8s.io/klog/v2"

	"rpi5.brmartin.co.uk/rpi5-dra-driver/pkg/driver"
	"rpi5.brmartin.co.uk/rpi5-dra-driver/pkg/resource"
)

func main() {
	ctx, cancel := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer cancel()

	nodeName := os.Getenv("NODE_NAME")
	if nodeName == "" {
		klog.Fatal("NODE_NAME env var required")
	}

	cfg, err := rest.InClusterConfig()
	if err != nil {
		klog.Fatalf("in-cluster config: %v", err)
	}
	client, err := kubernetes.NewForConfig(cfg)
	if err != nil {
		klog.Fatalf("kubernetes client: %v", err)
	}

	devices, found := driver.Discover()

	if err := resource.Publish(ctx, client, nodeName, devices, found); err != nil {
		klog.Fatalf("publish ResourceSlice: %v", err)
	}

	if !found {
		klog.Info("no Pi5 decode devices found — idling")
		<-ctx.Done()
		return
	}

	klog.Infof("Pi5 devices: H264=%v HEVC=%v RenderNode=%v",
		devices.HasH264, devices.HasHEVC, devices.HasRenderNode)

	plugin := driver.NewPlugin(devices)
	dp, err := kubeletplugin.Start(ctx, plugin,
		kubeletplugin.DriverName(driver.DriverName),
		kubeletplugin.KubeClient(client),
		kubeletplugin.NodeName(nodeName),
		kubeletplugin.PluginDataDirectoryPath(kubeletplugin.KubeletPluginsDir+"/"+driver.DriverName),
		kubeletplugin.PluginSocket("plugin.sock"),
		kubeletplugin.RegistrarSocketFilename(driver.DriverName+"-reg.sock"),
	)
	if err != nil {
		klog.Fatalf("start kubelet plugin: %v", err)
	}
	defer dp.Stop()

	klog.Info("rpi5-dra-driver running")
	<-ctx.Done()
}
