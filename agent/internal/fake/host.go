// Package fake replaces the agent's collectors with seed data from fixtures/
// for --fake mode, so the agent runs without root, Docker or systemd.
package fake

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io/fs"
	"path"
	"sync"
	"time"

	"github.com/AZAZ3LL0/samat-ssh/agent/internal/api/apitime"
	"github.com/AZAZ3LL0/samat-ssh/agent/internal/api/gen"
	"github.com/AZAZ3LL0/samat-ssh/agent/internal/collect/host"
)

// HostSampler replays fixtures/host_metrics in a loop, stamped with the current time.
type HostSampler struct {
	snapshots []gen.HostMetrics
	now       func() time.Time

	mu   sync.Mutex
	next int
}

var _ host.Sampler = (*HostSampler)(nil)

// NewHostSampler loads host_metrics/*.json from fixtures, in file name order.
func NewHostSampler(fixtures fs.FS, now func() time.Time) (*HostSampler, error) {
	files, err := fs.Glob(fixtures, "host_metrics/*.json")
	if err != nil {
		return nil, fmt.Errorf("list host metrics fixtures: %w", err)
	}
	if len(files) == 0 {
		return nil, errors.New("no host metrics fixtures in host_metrics/")
	}
	snapshots := make([]gen.HostMetrics, 0, len(files))
	for _, file := range files {
		data, err := fs.ReadFile(fixtures, file)
		if err != nil {
			return nil, fmt.Errorf("read fixture %s: %w", file, err)
		}
		var m gen.HostMetrics
		if err := json.Unmarshal(data, &m); err != nil {
			return nil, fmt.Errorf("decode fixture %s: %w", path.Base(file), err)
		}
		snapshots = append(snapshots, m)
	}
	return &HostSampler{snapshots: snapshots, now: now}, nil
}

// Sample implements host.Sampler.
func (s *HostSampler) Sample(context.Context) (gen.HostMetrics, error) {
	s.mu.Lock()
	m := s.snapshots[s.next]
	s.next = (s.next + 1) % len(s.snapshots)
	s.mu.Unlock()
	m.Ts = apitime.New(s.now())
	return m, nil
}
