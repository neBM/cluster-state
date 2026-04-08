package recycler

import (
	"context"
	"errors"
	"fmt"
	"os"
	"os/exec"
	"strings"
	"time"
)

const (
	defaultProbeInterval = 30 * time.Second
	defaultStatTimeout   = 2 * time.Second
	kubeletPodsPrefix    = "/var/lib/kubelet/pods/"
)

// Prober runs the periodic /proc/mountinfo + stat probe. Each unhealthy
// mountpoint is forwarded to Trigger as a string.
type Prober struct {
	ProcRoot    string
	StatPath    string
	StatTimeout time.Duration
	Interval    time.Duration
	Trigger     func(ctx context.Context, mountpoint string)
}

// Run blocks, running the probe every Interval until ctx is cancelled.
func (p *Prober) Run(ctx context.Context) {
	if p.Interval <= 0 {
		p.Interval = defaultProbeInterval
	}
	if p.StatTimeout <= 0 {
		p.StatTimeout = defaultStatTimeout
	}
	if p.StatPath == "" {
		if found, err := exec.LookPath("stat"); err == nil {
			p.StatPath = found
		} else {
			p.StatPath = "/usr/bin/stat"
		}
	}

	t := time.NewTicker(p.Interval)
	defer t.Stop()
	p.sweep(ctx)
	for {
		select {
		case <-ctx.Done():
			return
		case <-t.C:
			p.sweep(ctx)
		}
	}
}

func (p *Prober) sweep(ctx context.Context) {
	start := time.Now()
	defer func() { ProbeDurationSeconds.Observe(time.Since(start).Seconds()) }()

	data, err := os.ReadFile(p.ProcRoot + "/self/mountinfo")
	if err != nil {
		ProbeFailuresTotal.WithLabelValues("mountinfo-read").Inc()
		return
	}
	for _, mp := range parseMountinfo(string(data)) {
		if err := p.probeOne(ctx, mp); err != nil {
			if errors.Is(err, context.DeadlineExceeded) {
				ProbeFailuresTotal.WithLabelValues("stat-timeout").Inc()
			} else {
				ProbeFailuresTotal.WithLabelValues("stat-error").Inc()
			}
			if p.Trigger != nil {
				p.Trigger(ctx, mp)
			}
		}
	}
}

// probeOne execs <StatPath> <mountpoint> with a hard timeout.
func (p *Prober) probeOne(ctx context.Context, mountpoint string) error {
	cctx, cancel := context.WithTimeout(ctx, p.StatTimeout)
	defer cancel()
	cmd := exec.CommandContext(cctx, p.StatPath, mountpoint)
	if err := cmd.Run(); err != nil {
		if cctx.Err() == context.DeadlineExceeded {
			return context.DeadlineExceeded
		}
		return fmt.Errorf("stat %s: %w", mountpoint, err)
	}
	return nil
}

// parseMountinfo reads /proc/self/mountinfo and returns the mountpoint column
// for every fuse.seaweedfs mount that lives under kubeletPodsPrefix.
func parseMountinfo(s string) []string {
	var out []string
	for _, line := range strings.Split(s, "\n") {
		if line == "" {
			continue
		}
		sepIdx := strings.Index(line, " - ")
		if sepIdx < 0 {
			continue
		}
		left := strings.Fields(line[:sepIdx])
		right := strings.Fields(line[sepIdx+3:])
		if len(left) < 5 || len(right) < 1 {
			continue
		}
		mountpoint := left[4]
		fstype := right[0]
		if fstype != "fuse.seaweedfs" {
			continue
		}
		if !strings.HasPrefix(mountpoint, kubeletPodsPrefix) {
			continue
		}
		out = append(out, mountpoint)
	}
	return out
}
