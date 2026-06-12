package mountmanager

import (
	"context"
	"fmt"

	"google.golang.org/grpc"
	"google.golang.org/grpc/credentials/insecure"
	"google.golang.org/protobuf/types/known/emptypb"
)

const refreshVolumeLocationsMethod = "/messaging_pb.SeaweedMount/RefreshVolumeLocations"

func invokeRefreshVolumeLocations(ctx context.Context, localSocket string) error {
	target := fmt.Sprintf("passthrough:///unix://%s", localSocket)
	clientConn, err := grpc.DialContext(ctx, target, grpc.WithTransportCredentials(insecure.NewCredentials()))
	if err != nil {
		return err
	}
	defer clientConn.Close()

	var resp emptypb.Empty
	return clientConn.Invoke(ctx, refreshVolumeLocationsMethod, &emptypb.Empty{}, &resp)
}
