package mountmanager

import (
	"context"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"strconv"
	"time"

	"github.com/seaweedfs/seaweedfs/weed/glog"
)

const takeoverReadyTimeout = 10 * time.Second

func (m *Manager) TakeoverInventory(req *TakeoverInventoryRequest) (*TakeoverInventoryResponse, error) {
	if req == nil {
		return nil, errors.New("takeover inventory request is nil")
	}

	m.setTakeoverInProgress(true)

	resp := &TakeoverInventoryResponse{}
	for _, entry := range m.listMounts() {
		if entry == nil {
			continue
		}
		mount := takeoverMountFromEntry(entry)
		resp.Mounts = append(resp.Mounts, mount)
	}
	return resp, nil
}

func (m *Manager) ExportTakeover(req *TakeoverExportRequest) (*TakeoverExportResponse, error) {
	if req == nil {
		return nil, errors.New("takeover export request is nil")
	}
	if req.VolumeID == "" {
		return nil, errors.New("volumeId is required")
	}
	if req.HandoffSocket == "" {
		return nil, errors.New("handoffSocket is required")
	}

	lock := m.locks.get(req.VolumeID)
	lock.Lock()
	defer lock.Unlock()

	entry := m.getMount(req.VolumeID)
	if entry == nil {
		return nil, fmt.Errorf("volume %s is not mounted", req.VolumeID)
	}

	prepare, err := invokePrepareHotRestartFunc(context.Background(), entry.localSocket)
	if err != nil {
		return nil, fmt.Errorf("prepare hot restart for volume %s: %w", req.VolumeID, err)
	}

	resp := &TakeoverExportResponse{
		Accepted: prepare.Accepted,
		Status:   &prepare.Status,
	}
	if !prepare.Accepted {
		return resp, nil
	}

	fdFile, err := entry.process.dupMountFD()
	if err != nil {
		_, _ = m.CancelTakeover(&TakeoverCancelRequest{VolumeID: req.VolumeID})
		return nil, fmt.Errorf("duplicate live FUSE fd for volume %s: %w", req.VolumeID, err)
	}
	defer fdFile.Close()

	if err := sendFileDescriptor(req.HandoffSocket, fdFile); err != nil {
		_, _ = m.CancelTakeover(&TakeoverCancelRequest{VolumeID: req.VolumeID})
		return nil, fmt.Errorf("send live FUSE fd for volume %s: %w", req.VolumeID, err)
	}

	mount := takeoverMountFromEntry(entry)
	resp.Mount = &mount
	return resp, nil
}

func (m *Manager) FinalizeTakeover(req *TakeoverFinalizeRequest) (*TakeoverFinalizeResponse, error) {
	if req == nil {
		return nil, errors.New("takeover finalize request is nil")
	}
	if req.VolumeID == "" {
		return nil, errors.New("volumeId is required")
	}

	lock := m.locks.get(req.VolumeID)
	lock.Lock()
	defer lock.Unlock()

	entry := m.getMount(req.VolumeID)
	if entry == nil {
		return nil, fmt.Errorf("volume %s is not mounted", req.VolumeID)
	}

	entry.process.SetPreserveMountOnExit(true)
	if err := entry.process.stop(); err != nil {
		entry.process.SetPreserveMountOnExit(false)
		return nil, fmt.Errorf("stop old worker for volume %s: %w", req.VolumeID, err)
	}

	m.removeMount(req.VolumeID)
	return &TakeoverFinalizeResponse{}, nil
}

func (m *Manager) CancelTakeover(req *TakeoverCancelRequest) (*TakeoverCancelResponse, error) {
	if req == nil {
		return nil, errors.New("takeover cancel request is nil")
	}
	if req.VolumeID == "" {
		return nil, errors.New("volumeId is required")
	}

	lock := m.locks.get(req.VolumeID)
	lock.Lock()
	defer lock.Unlock()

	entry := m.getMount(req.VolumeID)
	if entry == nil {
		return nil, fmt.Errorf("volume %s is not mounted", req.VolumeID)
	}

	if err := invokeCancelHotRestartFunc(context.Background(), entry.localSocket); err != nil {
		return nil, fmt.Errorf("cancel hot restart for volume %s: %w", req.VolumeID, err)
	}
	entry.process.SetPreserveMountOnExit(false)
	return &TakeoverCancelResponse{}, nil
}

func (m *Manager) ReleaseTakeover(req *TakeoverReleaseRequest) (*TakeoverReleaseResponse, error) {
	if req == nil {
		return nil, errors.New("takeover release request is nil")
	}
	m.setTakeoverInProgress(false)
	return &TakeoverReleaseResponse{}, nil
}

func (m *Manager) TakeoverFrom(ctx context.Context, endpoint string) error {
	client, err := NewClient(endpoint)
	if err != nil {
		return err
	}
	scheme, address, err := ParseEndpoint(endpoint)
	if err != nil {
		return err
	}
	if scheme != "unix" {
		return fmt.Errorf("unsupported takeover endpoint scheme: %s", scheme)
	}
	releaseOnFailure := true
	defer func() {
		if !releaseOnFailure {
			return
		}
		releaseCtx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
		defer cancel()
		if _, releaseErr := client.ReleaseTakeover(releaseCtx); releaseErr != nil {
			glog.Warningf("release old mount-service takeover state at %s: %v", endpoint, releaseErr)
		}
	}()

	inventory, err := client.TakeoverInventory(ctx)
	if err != nil {
		return err
	}

	nonce := strconv.Itoa(os.Getpid())
	handoffDir := filepath.Dir(address)
	for _, mount := range inventory.Mounts {
		if err := m.takeoverMount(ctx, client, handoffDir, nonce, mount); err != nil {
			return err
		}
	}
	releaseOnFailure = false
	return nil
}

func (m *Manager) takeoverMount(ctx context.Context, client *Client, handoffDir string, nonce string, mount TakeoverMount) error {
	handoffSocket := HandoffSocketPath(handoffDir, nonce, mount.VolumeID)
	fdFile, exportResp, err := receiveExportedFileDescriptor(handoffSocket, func() (*TakeoverExportResponse, error) {
		return client.ExportTakeover(ctx, &TakeoverExportRequest{
			VolumeID:      mount.VolumeID,
			HandoffSocket: handoffSocket,
		})
	})
	if err != nil {
		return err
	}
	if exportResp == nil {
		return fmt.Errorf("takeover export for volume %s returned no response", mount.VolumeID)
	}
	if !exportResp.Accepted {
		status := exportResp.Status
		if status == nil {
			return fmt.Errorf("volume %s is not quiescent for takeover", mount.VolumeID)
		}
		return fmt.Errorf(
			"volume %s is not quiescent for takeover: open_file_handles=%d open_directory_handles=%d pending_async_flushes=%d",
			mount.VolumeID,
			status.OpenFileHandles,
			status.OpenDirectoryHandles,
			status.PendingAsyncFlushes,
		)
	}
	if fdFile == nil {
		return fmt.Errorf("takeover export for volume %s returned no live FUSE fd", mount.VolumeID)
	}
	defer fdFile.Close()

	if _, err := client.FinalizeTakeover(ctx, &TakeoverFinalizeRequest{VolumeID: mount.VolumeID}); err != nil {
		if _, cancelErr := client.CancelTakeover(ctx, &TakeoverCancelRequest{VolumeID: mount.VolumeID}); cancelErr != nil {
			glog.Warningf("cancel takeover after finalize failure for volume %s also failed: %v", mount.VolumeID, cancelErr)
		}
		return err
	}

	if exportResp.Mount != nil {
		mount = *exportResp.Mount
	}
	if err := m.importTakeoverMount(mount, fdFile); err != nil {
		return err
	}
	return nil
}

func (m *Manager) importTakeoverMount(mount TakeoverMount, fdFile *os.File) error {
	lock := m.locks.get(mount.VolumeID)
	lock.Lock()
	defer lock.Unlock()

	if err := os.Remove(mount.LocalSocket); err != nil && !errors.Is(err, os.ErrNotExist) {
		return fmt.Errorf("remove stale local socket for volume %s: %w", mount.VolumeID, err)
	}

	args := append([]string(nil), mount.MountArgs...)
	args = append(args,
		"-hotRestart.mountFd=3",
		"-hotRestart.adoptLiveFd=true",
	)

	process, err := startWeedMountProcessWithOptionsFunc(
		m.weedBinary,
		args,
		mount.TargetPath,
		mount.VolumeID,
		func() { m.detachMount(mount.VolumeID) },
		weedMountStartOptions{
			extraFiles: []*os.File{fdFile},
			ready: func() error {
				return waitForWorkerSocket(mount.LocalSocket, takeoverReadyTimeout)
			},
		},
	)
	if err != nil {
		return fmt.Errorf("start adopted worker for volume %s: %w", mount.VolumeID, err)
	}

	m.mu.Lock()
	m.mounts[mount.VolumeID] = &mountEntry{
		volumeID:    mount.VolumeID,
		targetPath:  mount.TargetPath,
		cacheDir:    mount.CacheDir,
		mountArgs:   append([]string(nil), mount.MountArgs...),
		localSocket: mount.LocalSocket,
		process:     process,
	}
	m.mu.Unlock()
	return nil
}

func takeoverMountFromEntry(entry *mountEntry) TakeoverMount {
	return TakeoverMount{
		VolumeID:    entry.volumeID,
		TargetPath:  entry.targetPath,
		CacheDir:    entry.cacheDir,
		MountArgs:   append([]string(nil), entry.mountArgs...),
		LocalSocket: entry.localSocket,
	}
}

func waitForWorkerSocket(localSocket string, timeout time.Duration) error {
	deadline := time.Now().Add(timeout)
	var lastErr error
	for {
		ctx, cancel := context.WithTimeout(context.Background(), 500*time.Millisecond)
		_, err := invokeHotRestartStatusFunc(ctx, localSocket)
		cancel()
		if err == nil {
			return nil
		}
		lastErr = err
		if time.Now().After(deadline) {
			return fmt.Errorf("timeout waiting for adopted worker socket %s: %w", localSocket, lastErr)
		}
		time.Sleep(25 * time.Millisecond)
	}
}
