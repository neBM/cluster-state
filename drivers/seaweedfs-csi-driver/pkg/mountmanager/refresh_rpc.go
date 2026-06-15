package mountmanager

import (
	"context"

	"github.com/seaweedfs/seaweedfs-csi-driver/pkg/mountpb"
)

func invokeRefreshVolumeLocations(ctx context.Context, localSocket string) error {
	clientConn, err := dialMountSocket(ctx, localSocket)
	if err != nil {
		return err
	}
	defer clientConn.Close()

	client := mountpb.NewSeaweedMountClient(clientConn)
	_, err = client.RefreshVolumeLocations(ctx, &mountpb.RefreshVolumeLocationsRequest{})
	return err
}
