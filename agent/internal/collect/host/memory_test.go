package host_test

import (
	"fmt"
	"testing"
	"testing/fstest"

	"pgregory.net/rapid"

	"github.com/AZAZ3LL0/samat-ssh/agent/internal/collect/host"
)

// Trimmed from an Ubuntu 24.04 VPS with 8 GiB of RAM.
const procMeminfo = `MemTotal:        8388608 kB
MemFree:          912340 kB
MemAvailable:    3040870 kB
Buffers:          102400 kB
Cached:          1572864 kB
SwapCached:            0 kB
Active:          4194304 kB
Inactive:        2097152 kB
HugePages_Total:       0
Hugepagesize:       2048 kB
`

func TestReadMemoryReportsBytes(t *testing.T) {
	memory, err := host.ReadMemory(fstest.MapFS{"meminfo": {Data: []byte(procMeminfo)}})
	if err != nil {
		t.Fatalf("read: %v", err)
	}
	if memory.TotalBytes != 8388608*1024 {
		t.Errorf("total = %d, want 8 GiB", memory.TotalBytes)
	}
	if memory.AvailableBytes != 3040870*1024 {
		t.Errorf("available = %d", memory.AvailableBytes)
	}
	if memory.UsedBytes != (8388608-3040870)*1024 {
		t.Errorf("used = %d, want total - available", memory.UsedBytes)
	}
	if memory.CachedBytes == nil || *memory.CachedBytes != 1572864*1024 {
		t.Errorf("cached = %v, want 1.5 GiB", memory.CachedBytes)
	}
}

func TestReadMemoryWithoutCachedReportsUnknown(t *testing.T) {
	memory, err := host.ParseMemory([]byte("MemTotal: 1024 kB\nMemAvailable: 512 kB\n"))
	if err != nil {
		t.Fatalf("parse: %v", err)
	}
	if memory.CachedBytes != nil {
		t.Errorf("cached = %d, want nil for a missing field", *memory.CachedBytes)
	}
}

func TestReadMemoryRejectsBrokenInput(t *testing.T) {
	cases := map[string]string{
		"no MemAvailable":         "MemTotal: 1024 kB\nCached: 1 kB\n",
		"no MemTotal":             "MemAvailable: 512 kB\n",
		"available above total":   "MemTotal: 512 kB\nMemAvailable: 1024 kB\n",
		"unexpected unit":         "MemTotal: 1024 MB\nMemAvailable: 512 kB\n",
		"non-numeric value":       "MemTotal: lots kB\nMemAvailable: 512 kB\n",
		"value overflows int64 B": "MemTotal: 9223372036854775807 kB\nMemAvailable: 1 kB\n",
	}
	for name, data := range cases {
		t.Run(name, func(t *testing.T) {
			if _, err := host.ParseMemory([]byte(data)); err == nil {
				t.Error("parsed without error")
			}
		})
	}
	if _, err := host.ReadMemory(fstest.MapFS{}); err == nil {
		t.Error("missing /proc/meminfo read without error")
	}
}

func TestMemoryUsedPlusAvailableIsTotal(t *testing.T) {
	rapid.Check(t, func(t *rapid.T) {
		total := rapid.Int64Range(0, 1<<40).Draw(t, "totalKiB")
		available := rapid.Int64Range(0, total).Draw(t, "availableKiB")
		memory, err := host.ParseMemory([]byte(fmt.Sprintf("MemTotal: %d kB\nMemAvailable: %d kB\n", total, available)))
		if err != nil {
			t.Fatalf("parse: %v", err)
		}
		if memory.UsedBytes < 0 || memory.UsedBytes+memory.AvailableBytes != memory.TotalBytes {
			t.Fatalf("used %d + available %d != total %d", memory.UsedBytes, memory.AvailableBytes, memory.TotalBytes)
		}
	})
}
