package host_test

import (
	"context"
	"errors"
	"io"
	"log/slog"
	"sync"
	"testing"
	"testing/fstest"
	"time"

	"github.com/AZAZ3LL0/samat-ssh/agent/internal/api/gen"
	"github.com/AZAZ3LL0/samat-ssh/agent/internal/collect/host"
)

func TestProcSamplerBuildsSnapshotFromProc(t *testing.T) {
	now := time.Date(2026, 11, 15, 10, 0, 0, 123456789, time.FixedZone("MSK", 3*60*60))
	proc := fstest.MapFS{
		"stat":    {Data: []byte(procStat)},
		"meminfo": {Data: []byte(procMeminfo)},
	}
	m, err := host.NewProcSampler(proc, func() time.Time { return now }).Sample(context.Background())
	if err != nil {
		t.Fatalf("sample: %v", err)
	}
	if want := time.Date(2026, 11, 15, 7, 0, 0, 123_000_000, time.UTC); !m.Ts.Equal(want) || m.Ts.Location() != time.UTC {
		t.Errorf("ts = %s, want %s in UTC with millisecond precision", m.Ts, want)
	}
	if m.Cpu.Cores != 2 || m.Cpu.PerCoreRatio == nil || len(*m.Cpu.PerCoreRatio) != 2 {
		t.Errorf("cpu = %+v, want 2 cores with per-core ratios", m.Cpu)
	}
	if iowait, err := m.Cpu.IowaitRatio.Get(); err != nil || iowait <= 0 {
		t.Errorf("iowait = %v (%v), want a measured ratio", iowait, err)
	}
	if m.Memory.UsedBytes != m.Memory.TotalBytes-m.Memory.AvailableBytes {
		t.Errorf("memory = %+v, want used = total - available", m.Memory)
	}
	if cached, err := m.Memory.CachedBytes.Get(); err != nil || cached != 1572864*1024 {
		t.Errorf("cached = %v (%v)", cached, err)
	}
}

func TestProcSamplerMeasuresBetweenCalls(t *testing.T) {
	proc := fstest.MapFS{
		"stat":    {Data: []byte("cpu  0 0 0 100 0 0 0 0\ncpu0 0 0 0 100 0 0 0 0\n")},
		"meminfo": {Data: []byte(procMeminfo)},
	}
	sampler := host.NewProcSampler(proc, time.Now)
	if _, err := sampler.Sample(context.Background()); err != nil {
		t.Fatalf("first sample: %v", err)
	}
	// The core was busy for the whole interval since the first call.
	proc["stat"] = &fstest.MapFile{Data: []byte("cpu  100 0 0 100 0 0 0 0\ncpu0 100 0 0 100 0 0 0 0\n")}
	m, err := sampler.Sample(context.Background())
	if err != nil {
		t.Fatalf("second sample: %v", err)
	}
	if m.Cpu.UsageRatio != 1 {
		t.Errorf("usage = %v, want 1 for a fully busy interval", m.Cpu.UsageRatio)
	}
}

func TestProcSamplerFailsWithoutProc(t *testing.T) {
	if _, err := host.NewProcSampler(fstest.MapFS{}, time.Now).Sample(context.Background()); err == nil {
		t.Error("sampled an empty /proc")
	}
}

func TestCollectorPublishesAndKeepsLatest(t *testing.T) {
	sampler := &scriptedSampler{results: []error{nil, errors.New("proc unreadable"), nil}}
	hub := &recordingPublisher{}
	collector := host.NewCollector(sampler, hub, "metrics.host", time.Millisecond, discard())

	if _, ok := collector.Latest(); ok {
		t.Fatal("latest is set before the first sample")
	}
	ctx, cancel := context.WithCancel(context.Background())
	done := make(chan struct{})
	go func() {
		collector.Run(ctx)
		close(done)
	}()
	waitFor(t, func() bool { return hub.count() >= 2 })
	cancel()
	<-done

	published := hub.snapshot()
	for _, p := range published {
		if p.topic != "metrics.host" {
			t.Errorf("published on %q, want metrics.host", p.topic)
		}
	}
	// The failed second sample is skipped, so the second publish is sample 3.
	if published[0].metrics.Cpu.Cores != 1 || published[1].metrics.Cpu.Cores != 3 {
		t.Errorf("published cores %d, %d; want 1, 3", published[0].metrics.Cpu.Cores, published[1].metrics.Cpu.Cores)
	}
	latest, ok := collector.Latest()
	if !ok || latest.Cpu.Cores < 3 {
		t.Errorf("latest = %+v, want the last successful sample", latest)
	}
}

// scriptedSampler fails on the calls whose result is an error and otherwise
// reports the call number as the core count.
type scriptedSampler struct {
	mu      sync.Mutex
	calls   int
	results []error
}

func (s *scriptedSampler) Sample(context.Context) (gen.HostMetrics, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.calls++
	if s.calls <= len(s.results) && s.results[s.calls-1] != nil {
		return gen.HostMetrics{}, s.results[s.calls-1]
	}
	var m gen.HostMetrics
	m.Cpu.Cores = s.calls
	return m, nil
}

type publication struct {
	topic   string
	metrics gen.HostMetrics
}

type recordingPublisher struct {
	mu   sync.Mutex
	seen []publication
}

func (p *recordingPublisher) Publish(topic string, payload any) {
	p.mu.Lock()
	defer p.mu.Unlock()
	p.seen = append(p.seen, publication{topic: topic, metrics: payload.(gen.HostMetrics)})
}

func (p *recordingPublisher) count() int {
	p.mu.Lock()
	defer p.mu.Unlock()
	return len(p.seen)
}

func (p *recordingPublisher) snapshot() []publication {
	p.mu.Lock()
	defer p.mu.Unlock()
	return append([]publication(nil), p.seen...)
}

func waitFor(t *testing.T, cond func() bool) {
	t.Helper()
	deadline := time.Now().Add(5 * time.Second)
	for !cond() {
		if time.Now().After(deadline) {
			t.Fatal("condition not met within 5s")
		}
		time.Sleep(time.Millisecond)
	}
}

func discard() *slog.Logger {
	return slog.New(slog.NewTextHandler(io.Discard, nil))
}
