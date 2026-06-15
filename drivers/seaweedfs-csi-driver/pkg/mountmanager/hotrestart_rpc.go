package mountmanager

import (
	"context"
	"fmt"

	"github.com/seaweedfs/seaweedfs-csi-driver/pkg/mountpb"
	"google.golang.org/grpc"
	"google.golang.org/grpc/credentials/insecure"
)

type HotRestartStatus struct {
	OpenFileHandles      uint64 `json:"openFileHandles"`
	OpenDirectoryHandles uint64 `json:"openDirectoryHandles"`
	PendingAsyncFlushes  uint64 `json:"pendingAsyncFlushes"`
	Quiescent            bool   `json:"quiescent"`
	BlockingNewHandles   bool   `json:"blockingNewHandles"`
}

type PrepareHotRestartResult struct {
	Accepted bool
	Status   HotRestartStatus
}

func invokeHotRestartStatus(ctx context.Context, localSocket string) (HotRestartStatus, error) {
	clientConn, err := dialMountSocket(ctx, localSocket)
	if err != nil {
		return HotRestartStatus{}, err
	}
	defer clientConn.Close()

	client := mountpb.NewSeaweedMountClient(clientConn)
	resp, err := client.HotRestartStatus(ctx, &mountpb.HotRestartStatusRequest{})
	if err != nil {
		return HotRestartStatus{}, err
	}
	return hotRestartStatusFromProto(resp), nil
}

func invokePrepareHotRestart(ctx context.Context, localSocket string) (PrepareHotRestartResult, error) {
	clientConn, err := dialMountSocket(ctx, localSocket)
	if err != nil {
		return PrepareHotRestartResult{}, err
	}
	defer clientConn.Close()

	client := mountpb.NewSeaweedMountClient(clientConn)
	resp, err := client.PrepareHotRestart(ctx, &mountpb.PrepareHotRestartRequest{})
	if err != nil {
		return PrepareHotRestartResult{}, err
	}

	result := PrepareHotRestartResult{
		Accepted: resp.GetAccepted(),
	}
	if resp.GetStatus() != nil {
		result.Status = hotRestartStatusFromProto(resp.GetStatus())
	}
	return result, nil
}

func invokeCancelHotRestart(ctx context.Context, localSocket string) error {
	clientConn, err := dialMountSocket(ctx, localSocket)
	if err != nil {
		return err
	}
	defer clientConn.Close()

	client := mountpb.NewSeaweedMountClient(clientConn)
	_, err = client.CancelHotRestart(ctx, &mountpb.CancelHotRestartRequest{})
	return err
}

func dialMountSocket(ctx context.Context, localSocket string) (*grpc.ClientConn, error) {
	target := fmt.Sprintf("passthrough:///unix://%s", localSocket)
	return grpc.DialContext(ctx, target, grpc.WithTransportCredentials(insecure.NewCredentials()))
}

func hotRestartStatusFromProto(resp *mountpb.HotRestartStatusResponse) HotRestartStatus {
	if resp == nil {
		return HotRestartStatus{}
	}

	return HotRestartStatus{
		OpenFileHandles:      resp.GetOpenFileHandles(),
		OpenDirectoryHandles: resp.GetOpenDirectoryHandles(),
		PendingAsyncFlushes:  resp.GetPendingAsyncFlushes(),
		Quiescent:            resp.GetQuiescent(),
		BlockingNewHandles:   resp.GetBlockingNewHandles(),
	}
}
