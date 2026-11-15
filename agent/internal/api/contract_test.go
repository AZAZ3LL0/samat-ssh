package api_test

import (
	"strconv"
	"testing"

	"github.com/AZAZ3LL0/samat-ssh/agent/internal/api/gen"
)

// The agent reports info.version as the integer apiVersion, so the embedded
// contract must carry a positive integer there.
func TestEmbeddedSpecVersionIsPositiveInteger(t *testing.T) {
	spec, err := gen.GetSpec()
	if err != nil {
		t.Fatalf("load embedded spec: %v", err)
	}
	version, err := strconv.Atoi(spec.Info.Version)
	if err != nil {
		t.Fatalf("info.version %q is not an integer: %v", spec.Info.Version, err)
	}
	if version < 1 {
		t.Fatalf("info.version = %d, want >= 1", version)
	}
}

func TestEmbeddedSpecDeclaresSkeletonEndpoints(t *testing.T) {
	spec, err := gen.GetSpec()
	if err != nil {
		t.Fatalf("load embedded spec: %v", err)
	}
	for _, path := range []string{"/v1/info", "/v1/pair", "/v1/metrics/host", "/v1/ws"} {
		if spec.Paths.Find(path) == nil {
			t.Errorf("path %s is missing from the contract", path)
		}
	}
}
