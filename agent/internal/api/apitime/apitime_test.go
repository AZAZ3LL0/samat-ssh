package apitime_test

import (
	"encoding/json"
	"testing"
	"time"

	"pgregory.net/rapid"

	"github.com/AZAZ3LL0/samat-ssh/agent/internal/api/apitime"
)

func TestMarshalAlwaysWritesMillisecondsInUTC(t *testing.T) {
	cases := map[string]time.Time{
		"2026-11-15T10:00:00.000Z": time.Date(2026, 11, 15, 10, 0, 0, 0, time.UTC),
		"2026-11-15T10:00:00.250Z": time.Date(2026, 11, 15, 10, 0, 0, 250_000_000, time.UTC),
		"2026-11-15T07:00:00.123Z": time.Date(2026, 11, 15, 10, 0, 0, 123_999_999, time.FixedZone("MSK", 3*60*60)),
	}
	for want, at := range cases {
		data, err := json.Marshal(apitime.New(at))
		if err != nil {
			t.Fatalf("marshal %s: %v", at, err)
		}
		if string(data) != `"`+want+`"` {
			t.Errorf("marshal %s = %s, want %q", at, data, want)
		}
	}
}

func TestUnmarshalAcceptsAnyRFC3339Precision(t *testing.T) {
	for _, text := range []string{"2026-11-15T10:00:00Z", "2026-11-15T10:00:00.5Z", "2026-11-15T13:00:00.123456789+03:00"} {
		var got apitime.Time
		if err := json.Unmarshal([]byte(`"`+text+`"`), &got); err != nil {
			t.Errorf("unmarshal %s: %v", text, err)
		}
	}
	var got apitime.Time
	if err := json.Unmarshal([]byte(`"yesterday"`), &got); err == nil {
		t.Error("unmarshalled a non-time")
	}
}

func TestRoundTripKeepsMillisecondsAndLayout(t *testing.T) {
	rapid.Check(t, func(t *rapid.T) {
		at := time.UnixMilli(rapid.Int64Range(0, 4102444800000).Draw(t, "ms"))
		data, err := json.Marshal(apitime.New(at))
		if err != nil {
			t.Fatalf("marshal: %v", err)
		}
		if len(data) != len(`"`+apitime.Layout+`"`) {
			t.Fatalf("%s does not have the fixed layout", data)
		}
		var back apitime.Time
		if err := json.Unmarshal(data, &back); err != nil {
			t.Fatalf("unmarshal %s: %v", data, err)
		}
		if !back.Equal(at) {
			t.Fatalf("round trip %s -> %s -> %s", at, data, back)
		}
	})
}
