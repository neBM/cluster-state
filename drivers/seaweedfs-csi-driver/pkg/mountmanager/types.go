package mountmanager

// MountRequest contains all information needed to start a weed mount process.
type MountRequest struct {
	VolumeID    string   `json:"volumeId"`
	TargetPath  string   `json:"targetPath"`
	CacheDir    string   `json:"cacheDir"`
	MountArgs   []string `json:"mountArgs"`
	LocalSocket string   `json:"localSocket"`
}

// MountResponse is returned after a successful mount request.
type MountResponse struct {
	LocalSocket string `json:"localSocket"`
}

// UnmountRequest contains the information needed to stop a weed mount process.
type UnmountRequest struct {
	VolumeID string `json:"volumeId"`
}

// UnmountResponse is the response of a successful unmount request.
type UnmountResponse struct{}

// RefreshVolumeLocationsRequest triggers an in-place volume-location cache
// refresh across all live weed mount subprocesses managed on the node.
type RefreshVolumeLocationsRequest struct{}

// RefreshVolumeLocationsFailure records a per-mount refresh failure.
type RefreshVolumeLocationsFailure struct {
	VolumeID    string `json:"volumeId"`
	LocalSocket string `json:"localSocket"`
	Error       string `json:"error"`
}

// RefreshVolumeLocationsResponse reports which local mounts were refreshed and
// which failed. Per-mount failures are reported in-band so callers can decide
// whether to fail closed without losing successful refreshes.
type RefreshVolumeLocationsResponse struct {
	Refreshed []string                        `json:"refreshed,omitempty"`
	Failed    []RefreshVolumeLocationsFailure `json:"failed,omitempty"`
}

type StartupMode string

const (
	StartupModeFresh         StartupMode = "fresh"
	StartupModeTakeover      StartupMode = "takeover"
	StartupModeCrashRecovery StartupMode = "crash_recovery"
)

type StartupStatusRequest struct{}

type StartupStatusResponse struct {
	Mode                 StartupMode `json:"mode"`
	ImportedMounts       int         `json:"importedMounts,omitempty"`
	RecoveredStaleMounts int         `json:"recoveredStaleMounts,omitempty"`
}

type TakeoverMount struct {
	VolumeID    string   `json:"volumeId"`
	TargetPath  string   `json:"targetPath"`
	CacheDir    string   `json:"cacheDir"`
	MountArgs   []string `json:"mountArgs"`
	LocalSocket string   `json:"localSocket"`
}

type TakeoverInventoryRequest struct{}

type TakeoverInventoryResponse struct {
	Mounts []TakeoverMount `json:"mounts,omitempty"`
}

type TakeoverExportRequest struct {
	VolumeID      string `json:"volumeId"`
	HandoffSocket string `json:"handoffSocket"`
}

type TakeoverExportResponse struct {
	Accepted bool              `json:"accepted"`
	Mount    *TakeoverMount    `json:"mount,omitempty"`
	Status   *HotRestartStatus `json:"status,omitempty"`
}

type TakeoverFinalizeRequest struct {
	VolumeID string `json:"volumeId"`
}

type TakeoverFinalizeResponse struct{}

type TakeoverCancelRequest struct {
	VolumeID string `json:"volumeId"`
}

type TakeoverCancelResponse struct{}

type TakeoverReleaseRequest struct{}

type TakeoverReleaseResponse struct{}

// ErrorResponse is returned when the mount service encounters a failure.
type ErrorResponse struct {
	Error string `json:"error"`
}

const (
	// DefaultWeedBinary is the default executable name used to spawn weed mount processes.
	DefaultWeedBinary = "weed"
)
