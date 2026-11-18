// Package apitime is the Go type of every date-time in the contract. tech.md
// §6.2 fixes the wire format to UTC with exactly three fractional digits;
// time.Time drops zero fractions ("…:00Z"), which the app's REST decoder,
// expecting fractional seconds, rejects.
package apitime

import (
	"fmt"
	"time"
)

// Layout is RFC 3339 in UTC with milliseconds: 2026-11-15T10:00:00.000Z.
const Layout = "2006-01-02T15:04:05.000Z"

// Time is a time.Time that encodes in Layout.
type Time struct {
	time.Time
}

// New converts t to UTC with millisecond precision, the precision the wire keeps.
func New(t time.Time) Time {
	return Time{t.UTC().Truncate(time.Millisecond)}
}

// MarshalText implements encoding.TextMarshaler; JSON and parameter binding use it.
func (t Time) MarshalText() ([]byte, error) {
	return []byte(t.UTC().Format(Layout)), nil
}

// UnmarshalText accepts any RFC 3339 time, so clients are not held to the
// agent's own precision.
func (t *Time) UnmarshalText(data []byte) error {
	parsed, err := time.Parse(time.RFC3339Nano, string(data))
	if err != nil {
		return fmt.Errorf("parse date-time %q: %w", data, err)
	}
	t.Time = parsed
	return nil
}

// MarshalJSON overrides the method promoted from the embedded time.Time,
// which would write a variable number of fractional digits.
func (t Time) MarshalJSON() ([]byte, error) {
	text, err := t.MarshalText()
	if err != nil {
		return nil, err
	}
	return []byte(`"` + string(text) + `"`), nil
}

// UnmarshalJSON overrides the promoted method, so decoding goes through UnmarshalText.
func (t *Time) UnmarshalJSON(data []byte) error {
	if len(data) < 2 || data[0] != '"' || data[len(data)-1] != '"' {
		return fmt.Errorf("date-time %s is not a JSON string", data)
	}
	return t.UnmarshalText(data[1 : len(data)-1])
}
