package host

import (
	"bufio"
	"bytes"
	"fmt"
	"io/fs"
	"strconv"
	"strings"
)

// Memory is one reading of /proc/meminfo, in bytes.
type Memory struct {
	TotalBytes     int64
	AvailableBytes int64
	// UsedBytes is total − available, the definition tech.md §2.4 fixes for
	// project attribution as well.
	UsedBytes int64
	// CachedBytes is nil when the kernel does not report Cached.
	CachedBytes *int64
}

// ReadMemory reads meminfo from fsys, which is rooted at /proc.
func ReadMemory(fsys fs.FS) (Memory, error) {
	data, err := fs.ReadFile(fsys, "meminfo")
	if err != nil {
		return Memory{}, fmt.Errorf("read /proc/meminfo: %w", err)
	}
	return ParseMemory(data)
}

// ParseMemory parses /proc/meminfo.
func ParseMemory(data []byte) (Memory, error) {
	fields := map[string]int64{}
	scanner := bufio.NewScanner(bytes.NewReader(data))
	for scanner.Scan() {
		name, rest, ok := strings.Cut(scanner.Text(), ":")
		if !ok {
			continue
		}
		switch name {
		case "MemTotal", "MemAvailable", "Cached":
		default:
			continue
		}
		value, err := parseKiB(rest)
		if err != nil {
			return Memory{}, fmt.Errorf("parse /proc/meminfo %s: %w", name, err)
		}
		fields[name] = value
	}
	if err := scanner.Err(); err != nil {
		return Memory{}, fmt.Errorf("scan /proc/meminfo: %w", err)
	}

	total, okTotal := fields["MemTotal"]
	// Every supported kernel (3.14+) reports MemAvailable; estimating it from
	// free + cache would quietly disagree with the attribution invariant.
	available, okAvailable := fields["MemAvailable"]
	if !okTotal || !okAvailable {
		return Memory{}, fmt.Errorf("parse /proc/meminfo: MemTotal or MemAvailable missing")
	}
	if available > total {
		return Memory{}, fmt.Errorf("parse /proc/meminfo: MemAvailable %d exceeds MemTotal %d", available, total)
	}
	memory := Memory{TotalBytes: total, AvailableBytes: available, UsedBytes: total - available}
	if cached, ok := fields["Cached"]; ok {
		memory.CachedBytes = &cached
	}
	return memory, nil
}

// parseKiB reads "  16316412 kB" as bytes.
func parseKiB(s string) (int64, error) {
	number, unit, _ := strings.Cut(strings.TrimSpace(s), " ")
	if unit != "kB" {
		return 0, fmt.Errorf("unit %q, want kB", unit)
	}
	kib, err := strconv.ParseInt(number, 10, 64)
	if err != nil {
		return 0, fmt.Errorf("value %q: %w", number, err)
	}
	if kib < 0 || kib > (1<<63-1)/1024 {
		return 0, fmt.Errorf("value %d kB out of range", kib)
	}
	return kib * 1024, nil
}
