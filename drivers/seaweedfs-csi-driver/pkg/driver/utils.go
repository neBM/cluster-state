package driver

import (
	"crypto/sha256"
	"encoding/hex"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"sync"

	"github.com/container-storage-interface/spec/lib/go/csi"
	"github.com/seaweedfs/seaweedfs-csi-driver/pkg/datalocality"
	"github.com/seaweedfs/seaweedfs-csi-driver/pkg/mountmanager"
	"github.com/seaweedfs/seaweedfs/weed/glog"
	"golang.org/x/net/context"
	"google.golang.org/grpc"
	"k8s.io/mount-utils"
)

func NewNodeServer(n *SeaweedFsDriver) *NodeServer {
	// NOTE: do NOT wipe n.CacheDir here. In the split-DaemonSet architecture
	// (csi-node + seaweedfs-mount) the cache dir is a hostPath shared with a
	// separate, long-lived weed mount process. csi-node restarts must not
	// touch that cache — doing so invalidates the LevelDB WAL backing the
	// live FUSE mounts and produces EIO on every inode the mount can no
	// longer resolve (see project_csi_v016_cache_wipe_fix). Per-volume
	// cleanup is the mount service's responsibility, triggered through the
	// Unmount RPC during NodeUnstageVolume.
	return &NodeServer{
		Driver:        n,
		volumeMutexes: NewKeyMutex(),
	}
}

func GetCacheDir(cacheBase, volumeID string) string {
	if cacheBase == "" {
		cacheBase = os.TempDir()
	}
	// volumeIDs are full paths in seaweedfs
	// Use hash value instead to get flat cache dir structure
	h := sha256.Sum256([]byte(volumeID))
	hashStr := hex.EncodeToString(h[:])
	return filepath.Join(cacheBase, hashStr)
}

func GetLocalSocket(volumeSocketDir, volumeID string) string {
	return mountmanager.LocalSocketPath(volumeSocketDir, volumeID)
}

func CleanupVolumeResources(driver *SeaweedFsDriver, volumeID string) {
	cacheDir := GetCacheDir(driver.CacheDir, volumeID)

	// Validate that cacheDir is within cacheBase to prevent path traversal
	cacheBase := driver.CacheDir
	if cacheBase == "" {
		cacheBase = os.TempDir()
	}
	cleanCacheBase := filepath.Clean(cacheBase)
	cleanCacheDir := filepath.Clean(cacheDir)
	rel, err := filepath.Rel(cleanCacheBase, cleanCacheDir)
	if err == nil && rel != "." && !strings.HasPrefix(rel, "..") {
		if err := os.RemoveAll(cleanCacheDir); err != nil {
			glog.Warningf("failed to remove cache dir %s for volume %s: %v", cleanCacheDir, volumeID, err)
		}
	} else {
		glog.Warningf("skipping cache dir removal for volume %s: invalid path %s (rel: %s, err: %v)", volumeID, cleanCacheDir, rel, err)
	}

	localSocket := GetLocalSocket(driver.volumeSocketDir, volumeID)
	if err := os.Remove(localSocket); err != nil && !os.IsNotExist(err) {
		glog.Warningf("failed to remove local socket %s for volume %s: %v", localSocket, volumeID, err)
	}
}

func NewIdentityServer(d *SeaweedFsDriver) *IdentityServer {
	return &IdentityServer{
		Driver: d,
	}
}

func NewControllerServer(d *SeaweedFsDriver) *ControllerServer {

	return &ControllerServer{
		Driver: d,
	}
}

func NewControllerServiceCapability(cap csi.ControllerServiceCapability_RPC_Type) *csi.ControllerServiceCapability {
	return &csi.ControllerServiceCapability{
		Type: &csi.ControllerServiceCapability_Rpc{
			Rpc: &csi.ControllerServiceCapability_RPC{
				Type: cap,
			},
		},
	}
}

func ParseEndpoint(ep string) (string, string, error) {
	if strings.HasPrefix(strings.ToLower(ep), "unix://") || strings.HasPrefix(strings.ToLower(ep), "tcp://") {
		s := strings.SplitN(ep, "://", 2)
		if s[1] != "" {
			return s[0], s[1], nil
		}
	}
	return "", "", fmt.Errorf("invalid endpoint: %v", ep)
}

func logGRPC(ctx context.Context, req interface{}, info *grpc.UnaryServerInfo, handler grpc.UnaryHandler) (interface{}, error) {
	glog.V(3).Infof("GRPC %s request %+v", info.FullMethod, req)
	resp, err := handler(ctx, req)
	if err != nil {
		glog.Errorf("GRPC error: %v", err)
	}
	glog.V(3).Infof("GRPC %s response %+v", info.FullMethod, resp)
	return resp, err
}

func checkMount(targetPath string) (bool, error) {
	isMnt, err := mountutil.IsMountPoint(targetPath)
	if err != nil {
		if os.IsNotExist(err) {
			if err = os.MkdirAll(targetPath, 0750); err != nil {
				return false, err
			}
			isMnt = false
		} else if mount.IsCorruptedMnt(err) {
			if err := mountutil.Unmount(targetPath); err != nil {
				return false, err
			}
			isMnt, err = mountutil.IsMountPoint(targetPath)
		} else {
			return false, err
		}
	}
	return isMnt, nil
}

type KeyMutex struct {
	mutexes sync.Map
}

func NewKeyMutex() *KeyMutex {
	return &KeyMutex{}
}

func (km *KeyMutex) GetMutex(key string) *sync.Mutex {
	m, _ := km.mutexes.LoadOrStore(key, &sync.Mutex{})

	return m.(*sync.Mutex)
}

func (km *KeyMutex) RemoveMutex(key string) {
	km.mutexes.Delete(key)
}

func CheckDataLocality(dataLocality *datalocality.DataLocality, dataCenter *string) error {
	if *dataLocality != datalocality.None && *dataCenter == "" {
		return fmt.Errorf("dataLocality set, but not all locality-definitions were set")
	}
	return nil
}
