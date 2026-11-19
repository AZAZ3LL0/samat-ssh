package fake_test

import (
	"context"
	"encoding/json"
	"os"
	"strconv"
	"testing"
	"testing/fstest"
	"time"

	"github.com/AZAZ3LL0/samat-ssh/agent/internal/api/contracttest"
	"github.com/AZAZ3LL0/samat-ssh/agent/internal/fake"
)

// The fake replays the shared seed data the app's FakeAgentClient also uses,
// and every snapshot it hands out is still a valid HostMetrics.
func TestHostSamplerReplaysRepositoryFixtures(t *testing.T) {
	fixtures := os.DirFS(contracttest.RepoPath("fixtures"))
	now := time.Date(2026, 11, 18, 12, 0, 0, 0, time.UTC)
	sampler, err := fake.NewHostSampler(fixtures, func() time.Time { return now })
	if err != nil {
		t.Fatalf("load: %v", err)
	}
	first, err := sampler.Sample(context.Background())
	if err != nil {
		t.Fatalf("sample: %v", err)
	}
	if !first.Ts.Equal(now) {
		t.Errorf("ts = %s, want the current time %s", first.Ts, now)
	}

	seen := map[float64]bool{}
	for range 10 {
		m, err := sampler.Sample(context.Background())
		if err != nil {
			t.Fatalf("sample: %v", err)
		}
		seen[m.Cpu.UsageRatio] = true
		payload, err := json.Marshal(m)
		if err != nil {
			t.Fatalf("encode: %v", err)
		}
		contracttest.RequireSchema(t, "HostMetrics", payload)
	}
	if len(seen) < 2 {
		t.Errorf("the fake repeated one value %v; the overview needs a moving series", seen)
	}
}

func TestHostSamplerLoopsInFileOrder(t *testing.T) {
	fixtures := fstest.MapFS{
		"host_metrics/02.json": {Data: []byte(snapshot(2))},
		"host_metrics/01.json": {Data: []byte(snapshot(1))},
	}
	sampler, err := fake.NewHostSampler(fixtures, time.Now)
	if err != nil {
		t.Fatalf("load: %v", err)
	}
	var cores []int
	for range 3 {
		m, _ := sampler.Sample(context.Background())
		cores = append(cores, m.Cpu.Cores)
	}
	if cores[0] != 1 || cores[1] != 2 || cores[2] != 1 {
		t.Errorf("cores = %v, want 1, 2, 1", cores)
	}
}

func TestHostSamplerNeedsFixtures(t *testing.T) {
	cases := map[string]fstest.MapFS{
		"empty":     {},
		"malformed": {"host_metrics/01.json": {Data: []byte("{")}},
	}
	for name, fixtures := range cases {
		t.Run(name, func(t *testing.T) {
			if _, err := fake.NewHostSampler(fixtures, time.Now); err == nil {
				t.Error("loaded without error")
			}
		})
	}
}

func snapshot(cores int) string {
	return `{"ts":"2026-11-15T10:00:00.000Z","cpu":{"usageRatio":0.1,"cores":` + strconv.Itoa(cores) +
		`},"memory":{"totalBytes":2,"usedBytes":1,"availableBytes":1}}`
}
