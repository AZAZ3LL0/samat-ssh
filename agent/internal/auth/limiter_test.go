package auth

import (
	"testing"
	"time"
)

func TestLimiterBlocksAfterTenFailuresInAMinute(t *testing.T) {
	c := &clock{t: time.Date(2026, 11, 15, 10, 0, 0, 0, time.UTC)}
	limiter := NewLimiter(c.now)

	for range 9 {
		limiter.Fail("10.0.0.1")
		c.advance(time.Second)
	}
	if limiter.Blocked("10.0.0.1") {
		t.Fatal("blocked after 9 failures")
	}
	limiter.Fail("10.0.0.1")
	if !limiter.Blocked("10.0.0.1") {
		t.Fatal("not blocked after 10 failures within a minute")
	}
	if limiter.Blocked("10.0.0.2") {
		t.Error("another address is blocked")
	}

	c.advance(5*time.Minute - time.Second)
	if !limiter.Blocked("10.0.0.1") {
		t.Error("block lifted before 5 minutes")
	}
	c.advance(time.Second)
	if limiter.Blocked("10.0.0.1") {
		t.Error("still blocked after 5 minutes")
	}
}

func TestLimiterIgnoresFailuresOlderThanAMinute(t *testing.T) {
	c := &clock{t: time.Date(2026, 11, 15, 10, 0, 0, 0, time.UTC)}
	limiter := NewLimiter(c.now)

	// One failure every 7 seconds never puts 10 inside a single minute.
	for range 30 {
		limiter.Fail("10.0.0.1")
		c.advance(7 * time.Second)
	}
	if limiter.Blocked("10.0.0.1") {
		t.Fatal("blocked although no minute held 10 failures")
	}
}
