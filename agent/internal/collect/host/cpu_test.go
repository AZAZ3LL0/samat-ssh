package host_test

import (
	"math"
	"testing"
	"testing/fstest"

	"pgregory.net/rapid"

	"github.com/AZAZ3LL0/samat-ssh/agent/internal/collect/host"
)

const procStat = `cpu  100 0 50 800 20 0 10 20 0 0
cpu0 50 0 25 400 10 0 5 10 0 0
cpu1 50 0 25 400 10 0 5 10 0 0
intr 12345 0 0
ctxt 67890
btime 1763200000
processes 4242
`

func TestReadCPUStatParsesHostAndCoreLines(t *testing.T) {
	stat, err := host.ReadCPUStat(fstest.MapFS{"stat": {Data: []byte(procStat)}})
	if err != nil {
		t.Fatalf("read: %v", err)
	}
	want := host.CPUTimes{User: 100, System: 50, Idle: 800, Iowait: 20, SoftIRQ: 10, Steal: 20}
	if stat.Total != want {
		t.Errorf("total = %+v, want %+v", stat.Total, want)
	}
	if len(stat.PerCore) != 2 {
		t.Fatalf("cores = %d, want 2", len(stat.PerCore))
	}
}

func TestReadCPUStatRejectsBrokenInput(t *testing.T) {
	cases := map[string]string{
		"no cpu lines":    "intr 1 2 3\n",
		"no core lines":   "cpu  1 2 3 4 5 6 7 8 0 0\n",
		"short line":      "cpu  1 2 3\ncpu0 1 2 3\n",
		"non-numeric":     "cpu  1 2 x 4 5 6 7 8\ncpu0 1 2 3 4 5 6 7 8\n",
		"negative number": "cpu  1 2 -3 4 5 6 7 8\ncpu0 1 2 3 4 5 6 7 8\n",
	}
	for name, data := range cases {
		t.Run(name, func(t *testing.T) {
			if _, err := host.ReadCPUStat(fstest.MapFS{"stat": {Data: []byte(data)}}); err == nil {
				t.Error("parsed without error")
			}
		})
	}
	if _, err := host.ReadCPUStat(fstest.MapFS{}); err == nil {
		t.Error("missing /proc/stat read without error")
	}
}

func TestUsageReportsTopStylePercentAndRatios(t *testing.T) {
	prev := host.CPUStat{
		Total:   host.CPUTimes{User: 1000, Idle: 3000},
		PerCore: make([]host.CPUTimes, 4),
	}
	// Over 400 jiffies on 4 cores: two cores fully busy, one idle, one waiting on disk.
	cur := host.CPUStat{
		Total: host.CPUTimes{User: 1150, System: 50, Idle: 3100, Iowait: 60, Steal: 40},
		PerCore: []host.CPUTimes{
			{User: 100},
			{User: 50, System: 50},
			{Idle: 100},
			{Iowait: 60, Steal: 40},
		},
	}
	usage := host.Usage(prev, cur)

	if usage.Cores != 4 {
		t.Errorf("cores = %d, want 4", usage.Cores)
	}
	// Busy = user + system + steal = 240 of 400 jiffies on 4 cores.
	assertNear(t, "percent", usage.Percent, 240)
	assertNear(t, "usage ratio", usage.UsageRatio(), 0.6)
	assertNear(t, "iowait ratio", usage.IowaitRatio, 0.15)
	assertNear(t, "steal ratio", usage.StealRatio, 0.1)
	want := []float64{1, 1, 0, 0.4}
	for i, got := range usage.PerCoreRatio() {
		assertNear(t, "core ratio", got, want[i])
	}
}

func TestUsageFromZeroIsAverageSinceBoot(t *testing.T) {
	stat, err := host.ParseCPUStat([]byte(procStat))
	if err != nil {
		t.Fatalf("parse: %v", err)
	}
	// Busy = 1000 jiffies - idle 800 - iowait 20.
	assertNear(t, "usage ratio", host.Usage(host.CPUStat{}, stat).UsageRatio(), 0.18)
}

func TestUsageWithoutElapsedTimeIsZero(t *testing.T) {
	stat, err := host.ParseCPUStat([]byte(procStat))
	if err != nil {
		t.Fatalf("parse: %v", err)
	}
	usage := host.Usage(stat, stat)
	if usage.Percent != 0 || usage.IowaitRatio != 0 || usage.StealRatio != 0 {
		t.Errorf("usage = %+v, want zero", usage)
	}
}

func TestUsageTreatsWrappedCountersAsNoProgress(t *testing.T) {
	near := uint64(math.MaxUint64 - 10)
	prev := host.CPUStat{
		Total:   host.CPUTimes{User: near, Idle: near, Iowait: near},
		PerCore: []host.CPUTimes{{User: near, Idle: near, Iowait: near}},
	}
	cur := host.CPUStat{
		Total:   host.CPUTimes{User: 5, Idle: 5, Iowait: 5},
		PerCore: []host.CPUTimes{{User: 5, Idle: 5, Iowait: 5}},
	}
	usage := host.Usage(prev, cur)
	if usage.Percent != 0 || usage.PerCorePercent[0] != 0 || usage.IowaitRatio != 0 {
		t.Errorf("usage after wraparound = %+v, want zero", usage)
	}
}

// Properties from tech.md §12: CPU percent from counter deltas stays within
// [0, 100 × cores] for any readings, including counters that wrapped or went
// backwards, and every ratio the API reports stays within 0..1.
func TestUsagePropertiesHoldForAnyCounters(t *testing.T) {
	rapid.Check(t, func(t *rapid.T) {
		cores := rapid.IntRange(1, 256).Draw(t, "cores")
		// prev may know fewer cores: a core can come online between readings.
		prev := drawStat(t, "prev", rapid.IntRange(0, cores).Draw(t, "prevCores"))
		cur := drawStat(t, "cur", cores)

		usage := host.Usage(prev, cur)
		if usage.Cores != cores {
			t.Fatalf("cores = %d, want %d", usage.Cores, cores)
		}
		inRange(t, "percent", usage.Percent, 0, 100*float64(cores))
		inRange(t, "usage ratio", usage.UsageRatio(), 0, 1)
		inRange(t, "iowait ratio", usage.IowaitRatio, 0, 1)
		inRange(t, "steal ratio", usage.StealRatio, 0, 1)
		if len(usage.PerCoreRatio()) != cores {
			t.Fatalf("per-core ratios = %d, want %d", len(usage.PerCoreRatio()), cores)
		}
		for _, r := range usage.PerCoreRatio() {
			inRange(t, "core ratio", r, 0, 1)
		}
	})
}

func TestUsageNeverExceedsWhatAdvancingCountersAllow(t *testing.T) {
	rapid.Check(t, func(t *rapid.T) {
		prev := drawTimes(t, "prev")
		idle := rapid.Uint64Range(1, 1<<40).Draw(t, "idle")
		cur := prev
		cur.Idle += idle
		// Only idle advanced, so the host was not busy at all.
		usage := host.Usage(host.CPUStat{Total: prev, PerCore: []host.CPUTimes{prev}},
			host.CPUStat{Total: cur, PerCore: []host.CPUTimes{cur}})
		if usage.Percent != 0 {
			t.Fatalf("percent = %v while only idle advanced", usage.Percent)
		}
	})
}

func drawStat(t *rapid.T, label string, cores int) host.CPUStat {
	stat := host.CPUStat{Total: drawTimes(t, label+".total")}
	for range cores {
		stat.PerCore = append(stat.PerCore, drawTimes(t, label+".core"))
	}
	return stat
}

func drawTimes(t *rapid.T, label string) host.CPUTimes {
	// Full uint64 range, so sums and differences hit wraparound.
	v := rapid.Uint64()
	return host.CPUTimes{
		User: v.Draw(t, label+".user"), Nice: v.Draw(t, label+".nice"),
		System: v.Draw(t, label+".system"), Idle: v.Draw(t, label+".idle"),
		Iowait: v.Draw(t, label+".iowait"), IRQ: v.Draw(t, label+".irq"),
		SoftIRQ: v.Draw(t, label+".softirq"), Steal: v.Draw(t, label+".steal"),
	}
}

func inRange(t *rapid.T, name string, v, lo, hi float64) {
	if math.IsNaN(v) || v < lo || v > hi {
		t.Fatalf("%s = %v, want within [%v, %v]", name, v, lo, hi)
	}
}

func assertNear(t *testing.T, name string, got, want float64) {
	t.Helper()
	if math.Abs(got-want) > 1e-9 {
		t.Errorf("%s = %v, want %v", name, got, want)
	}
}
