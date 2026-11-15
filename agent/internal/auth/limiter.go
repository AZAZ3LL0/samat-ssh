package auth

import (
	"sync"
	"time"
)

const (
	maxFailures   = 10
	failureWindow = time.Minute
	blockDuration = 5 * time.Minute
	// Above this many tracked addresses a failure also sweeps stale entries,
	// so a scan from many sources cannot grow the map without bound.
	sweepThreshold = 1024
)

// Limiter blocks an address after too many failed authorization attempts:
// 10 failures within a minute block it for 5 minutes.
type Limiter struct {
	now func() time.Time

	mu      sync.Mutex
	entries map[string]*limiterEntry
}

type limiterEntry struct {
	failures     []time.Time
	blockedUntil time.Time
}

// NewLimiter returns a Limiter reading time from now.
func NewLimiter(now func() time.Time) *Limiter {
	return &Limiter{now: now, entries: make(map[string]*limiterEntry)}
}

// Blocked reports whether addr is currently blocked.
func (l *Limiter) Blocked(addr string) bool {
	l.mu.Lock()
	defer l.mu.Unlock()
	entry, ok := l.entries[addr]
	return ok && l.now().Before(entry.blockedUntil)
}

// Fail records a failed attempt from addr.
func (l *Limiter) Fail(addr string) {
	l.mu.Lock()
	defer l.mu.Unlock()
	now := l.now()
	if len(l.entries) >= sweepThreshold {
		l.sweep(now)
	}
	entry, ok := l.entries[addr]
	if !ok {
		entry = &limiterEntry{}
		l.entries[addr] = entry
	}
	entry.failures = recent(entry.failures, now)
	entry.failures = append(entry.failures, now)
	if len(entry.failures) >= maxFailures {
		entry.blockedUntil = now.Add(blockDuration)
		entry.failures = nil
	}
}

func (l *Limiter) sweep(now time.Time) {
	for addr, entry := range l.entries {
		if len(recent(entry.failures, now)) == 0 && !now.Before(entry.blockedUntil) {
			delete(l.entries, addr)
		}
	}
}

// recent keeps the failures still inside the window.
func recent(failures []time.Time, now time.Time) []time.Time {
	kept := failures[:0]
	for _, at := range failures {
		if now.Sub(at) < failureWindow {
			kept = append(kept, at)
		}
	}
	return kept
}
