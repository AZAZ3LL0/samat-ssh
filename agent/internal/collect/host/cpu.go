// Package host collects host-wide metrics from /proc.
package host

import (
	"bufio"
	"bytes"
	"errors"
	"fmt"
	"io/fs"
	"strconv"
	"strings"
)

// CPUTimes are the cumulative jiffies of one cpu line in /proc/stat.
type CPUTimes struct {
	User, Nice, System, Idle, Iowait, IRQ, SoftIRQ, Steal uint64
}

// total excludes guest and guest_nice: the kernel already counts them in user
// and nice. It sums in float64 so huge deltas cannot wrap around.
func (t CPUTimes) total() float64 {
	sum := 0.0
	for _, v := range []uint64{t.User, t.Nice, t.System, t.Idle, t.Iowait, t.IRQ, t.SoftIRQ, t.Steal} {
		sum += float64(v)
	}
	return sum
}

// CPUStat is one reading of /proc/stat: the host line and one line per online core.
type CPUStat struct {
	Total   CPUTimes
	PerCore []CPUTimes
}

// CPUUsage is the CPU load between two readings.
type CPUUsage struct {
	Cores int
	// Percent is top-style: 100 per fully busy core, so 0..100 × Cores.
	Percent        float64
	PerCorePercent []float64
	IowaitRatio    float64
	StealRatio     float64
}

// UsageRatio is the share of the whole host's capacity, as the API reports it.
func (u CPUUsage) UsageRatio() float64 {
	return PercentToRatio(u.Percent, u.Cores)
}

// PerCoreRatio reports each core's load as a share of that core.
func (u CPUUsage) PerCoreRatio() []float64 {
	ratios := make([]float64, len(u.PerCorePercent))
	for i, pct := range u.PerCorePercent {
		ratios[i] = PercentToRatio(pct, 1)
	}
	return ratios
}

// PercentToRatio converts top-style percent over cores into a 0..1 share.
func PercentToRatio(pct float64, cores int) float64 {
	if cores <= 0 {
		return 0
	}
	return clamp(pct/(100*float64(cores)), 0, 1)
}

// ReadCPUStat reads stat from fsys, which is rooted at /proc.
func ReadCPUStat(fsys fs.FS) (CPUStat, error) {
	data, err := fs.ReadFile(fsys, "stat")
	if err != nil {
		return CPUStat{}, fmt.Errorf("read /proc/stat: %w", err)
	}
	return ParseCPUStat(data)
}

// ParseCPUStat parses the cpu lines of /proc/stat.
func ParseCPUStat(data []byte) (CPUStat, error) {
	var stat CPUStat
	seenTotal := false
	scanner := bufio.NewScanner(bytes.NewReader(data))
	for scanner.Scan() {
		fields := strings.Fields(scanner.Text())
		if len(fields) == 0 || !strings.HasPrefix(fields[0], "cpu") {
			continue
		}
		times, err := parseCPULine(fields[1:])
		if err != nil {
			return CPUStat{}, fmt.Errorf("parse /proc/stat %s: %w", fields[0], err)
		}
		if fields[0] == "cpu" {
			stat.Total, seenTotal = times, true
		} else {
			stat.PerCore = append(stat.PerCore, times)
		}
	}
	if err := scanner.Err(); err != nil {
		return CPUStat{}, fmt.Errorf("scan /proc/stat: %w", err)
	}
	if !seenTotal || len(stat.PerCore) == 0 {
		return CPUStat{}, errors.New("parse /proc/stat: no cpu lines")
	}
	return stat, nil
}

func parseCPULine(fields []string) (CPUTimes, error) {
	// Kernels before 2.6.11 report fewer than 8 columns; supported ones have 10.
	if len(fields) < 8 {
		return CPUTimes{}, fmt.Errorf("%d columns, want at least 8", len(fields))
	}
	var values [8]uint64
	for i := range values {
		v, err := strconv.ParseUint(fields[i], 10, 64)
		if err != nil {
			return CPUTimes{}, fmt.Errorf("column %d: %w", i+1, err)
		}
		values[i] = v
	}
	return CPUTimes{
		User: values[0], Nice: values[1], System: values[2], Idle: values[3],
		Iowait: values[4], IRQ: values[5], SoftIRQ: values[6], Steal: values[7],
	}, nil
}

// Usage returns the load between prev and cur. A zero prev yields the
// average since boot. A counter that went backwards (iowait does on some
// kernels, and a wrapped counter looks the same) counts as no progress
// instead of a huge unsigned difference.
func Usage(prev, cur CPUStat) CPUUsage {
	cores := len(cur.PerCore)
	usage := CPUUsage{Cores: cores, PerCorePercent: make([]float64, cores)}

	total, busy, iowait, steal := deltas(prev.Total, cur.Total)
	if total > 0 {
		usage.Percent = clamp(100*float64(cores)*busy/total, 0, 100*float64(cores))
		usage.IowaitRatio = clamp(iowait/total, 0, 1)
		usage.StealRatio = clamp(steal/total, 0, 1)
	}
	for i, now := range cur.PerCore {
		var before CPUTimes
		// A core that came online since prev has no earlier reading.
		if i < len(prev.PerCore) {
			before = prev.PerCore[i]
		}
		if t, b, _, _ := deltas(before, now); t > 0 {
			usage.PerCorePercent[i] = clamp(100*b/t, 0, 100)
		}
	}
	return usage
}

func deltas(prev, cur CPUTimes) (total, busy, iowait, steal float64) {
	d := CPUTimes{
		User: delta(prev.User, cur.User), Nice: delta(prev.Nice, cur.Nice),
		System: delta(prev.System, cur.System), Idle: delta(prev.Idle, cur.Idle),
		Iowait: delta(prev.Iowait, cur.Iowait), IRQ: delta(prev.IRQ, cur.IRQ),
		SoftIRQ: delta(prev.SoftIRQ, cur.SoftIRQ), Steal: delta(prev.Steal, cur.Steal),
	}
	total = d.total()
	// Iowait is time the CPU sat idle waiting for disks, so it is not busy time.
	busy = total - float64(d.Idle) - float64(d.Iowait)
	return total, busy, float64(d.Iowait), float64(d.Steal)
}

func delta(prev, cur uint64) uint64 {
	if cur < prev {
		return 0
	}
	return cur - prev
}

func clamp(v, lo, hi float64) float64 {
	return max(lo, min(hi, v))
}
