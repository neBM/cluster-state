package mountmanager

import (
	"context"
	"fmt"

	"github.com/seaweedfs/seaweedfs/weed/pb/mount_pb"
	"google.golang.org/grpc"
	"google.golang.org/grpc/credentials/insecure"
)

func invokeRefreshVolumeLocations(ctx context.Context, localSocket string) error {
	target := fmt.Sprintf("passthrough:///unix://%s", localSocket)
	clientConn, err := grpc.DialContext(ctx, target, grpc.WithTransportCredentials(insecure.NewCredentials()))
	if err != nil {
		return err
	}
	defer clientConn.Close()

	client := mount_pb.NewSeaweedMountClient(clientConn)
	_, err = client.RefreshVolumeLocations(ctx, &mount_pb.RefreshVolumeLocationsRequest{})
	return err
}
