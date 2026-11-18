package host

import (
	"context"
	"io/fs"
	"log/slog"
	"sync"
	"time"

	"github.com/oapi-codegen/nullable"

	"github.com/AZAZ3LL0/samat-ssh/agent/internal/api/gen"
)

// Interval is how often the host is sampled and metrics.host is published.
const Interval = time.Second

// Sampler produces one HostMetrics snapshot per call.
type Sampler interface {
	Sample(ctx context.Context) (gen.HostMetrics, error)
}

// Publisher fans a snapshot out to subscribers; *ws.Hub implements it.
type Publisher interface {
	Publish(topic string, payload any)
}

// ProcSampler reads the host from /proc. CPU load is the delta to the
// previous call, so the first call reports the average since boot.
type ProcSampler struct {
	proc fs.FS
	now  func() time.Time

	mu   sync.Mutex
	prev CPUStat
}

// NewProcSampler samples the /proc tree in proc.
func NewProcSampler(proc fs.FS, now func() time.Time) *ProcSampler {
	return &ProcSampler{proc: proc, now: now}
}

// Sample implements Sampler.
func (s *ProcSampler) Sample(_ context.Context) (gen.HostMetrics, error) {
	stat, err := ReadCPUStat(s.proc)
	if err != nil {
		return gen.HostMetrics{}, err
	}
	memory, err := ReadMemory(s.proc)
	if err != nil {
		return gen.HostMetrics{}, err
	}
	s.mu.Lock()
	usage := Usage(s.prev, stat)
	s.prev = stat
	s.mu.Unlock()

	var m gen.HostMetrics
	m.Ts = Timestamp(s.now())
	m.Cpu.Cores = usage.Cores
	m.Cpu.UsageRatio = usage.UsageRatio()
	perCore := usage.PerCoreRatio()
	m.Cpu.PerCoreRatio = &perCore
	m.Cpu.IowaitRatio = nullable.NewNullableWithValue(usage.IowaitRatio)
	m.Cpu.StealRatio = nullable.NewNullableWithValue(usage.StealRatio)
	m.Memory.TotalBytes = memory.TotalBytes
	m.Memory.AvailableBytes = memory.AvailableBytes
	m.Memory.UsedBytes = memory.UsedBytes
	if memory.CachedBytes != nil {
		m.Memory.CachedBytes = nullable.NewNullableWithValue(*memory.CachedBytes)
	} else {
		m.Memory.CachedBytes = nullable.NewNullNullable[int64]()
	}
	return m, nil
}

// Timestamp brings t to the API time format: UTC with millisecond precision.
func Timestamp(t time.Time) time.Time {
	return t.UTC().Truncate(time.Millisecond)
}

// Collector samples the host every Interval, keeps the latest snapshot for
// GET /v1/metrics/host and publishes it on metrics.host.
type Collector struct {
	sampler  Sampler
	publish  Publisher
	topic    string
	interval time.Duration
	logger   *slog.Logger

	mu     sync.RWMutex
	latest *gen.HostMetrics
}

// NewCollector returns a collector publishing on topic every interval.
func NewCollector(sampler Sampler, publish Publisher, topic string, interval time.Duration, logger *slog.Logger) *Collector {
	return &Collector{sampler: sampler, publish: publish, topic: topic, interval: interval, logger: logger}
}

// Run samples immediately, then on every tick, until ctx is cancelled.
func (c *Collector) Run(ctx context.Context) {
	ticker := time.NewTicker(c.interval)
	defer ticker.Stop()
	for {
		c.collect(ctx)
		select {
		case <-ctx.Done():
			return
		case <-ticker.C:
		}
	}
}

func (c *Collector) collect(ctx context.Context) {
	metrics, err := c.sampler.Sample(ctx)
	if err != nil {
		// A failed sample keeps the previous snapshot; clients see its ts age.
		c.logger.WarnContext(ctx, "sample host metrics", "error", err)
		return
	}
	c.mu.Lock()
	c.latest = &metrics
	c.mu.Unlock()
	c.publish.Publish(c.topic, metrics)
}

// Latest returns the most recent snapshot; false until the first sample succeeds.
func (c *Collector) Latest() (gen.HostMetrics, bool) {
	c.mu.RLock()
	defer c.mu.RUnlock()
	if c.latest == nil {
		return gen.HostMetrics{}, false
	}
	return *c.latest, true
}
