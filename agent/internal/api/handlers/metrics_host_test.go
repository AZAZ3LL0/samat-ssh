package handlers_test

import (
	"context"
	"encoding/json"
	"io"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"path/filepath"
	"slices"
	"testing"
	"time"

	"github.com/oapi-codegen/nullable"

	"github.com/AZAZ3LL0/samat-ssh/agent/internal/api"
	"github.com/AZAZ3LL0/samat-ssh/agent/internal/api/contracttest"
	"github.com/AZAZ3LL0/samat-ssh/agent/internal/api/gen"
	"github.com/AZAZ3LL0/samat-ssh/agent/internal/api/handlers"
	"github.com/AZAZ3LL0/samat-ssh/agent/internal/auth"
	"github.com/AZAZ3LL0/samat-ssh/agent/internal/store"
	"github.com/AZAZ3LL0/samat-ssh/agent/internal/ws"
)

// snapshotSource is a HostMetricsSource with a fixed answer.
type snapshotSource struct {
	metrics gen.HostMetrics
	ok      bool
}

func (s snapshotSource) Latest() (gen.HostMetrics, bool) { return s.metrics, s.ok }

// stack serves the full API behind the contract validator and returns a device token.
func stack(t *testing.T, source handlers.HostMetricsSource) (http.Handler, string) {
	t.Helper()
	st, err := store.Open(context.Background(), filepath.Join(t.TempDir(), "pulse.db"))
	if err != nil {
		t.Fatalf("open store: %v", err)
	}
	t.Cleanup(func() { _ = st.Close() })
	service := auth.NewService(st, time.Now)
	logger := slog.New(slog.NewTextHandler(io.Discard, nil))
	hub := ws.NewHub(ws.DefaultConfig(), time.Now, logger)
	t.Cleanup(hub.Close)

	handler, err := api.NewHandler(api.Deps{
		AgentVersion: "0.3.1", Hostname: "vps-1", Auth: service, Limiter: auth.NewLimiter(time.Now),
		Hub: hub, HostMetrics: source, Logger: logger,
	})
	if err != nil {
		t.Fatalf("build handler: %v", err)
	}
	code, _, err := service.NewPairingCode(context.Background())
	if err != nil {
		t.Fatalf("pairing code: %v", err)
	}
	token, _, err := service.Pair(context.Background(), code, "iPhone")
	if err != nil {
		t.Fatalf("pair: %v", err)
	}
	return contracttest.Middleware(t)(handler), token
}

func get(t *testing.T, handler http.Handler, path, token string) *httptest.ResponseRecorder {
	t.Helper()
	request := httptest.NewRequest(http.MethodGet, path, nil)
	if token != "" {
		request.Header.Set("Authorization", "Bearer "+token)
	}
	recorder := httptest.NewRecorder()
	handler.ServeHTTP(recorder, request)
	if recorder.Header().Get("X-Request-Id") == "" {
		t.Errorf("GET %s has no X-Request-Id", path)
	}
	return recorder
}

func sample() gen.HostMetrics {
	var m gen.HostMetrics
	m.Ts = time.Date(2026, 11, 15, 10, 0, 0, 250_000_000, time.UTC)
	m.Cpu.UsageRatio = 0.42
	m.Cpu.Cores = 2
	m.Cpu.PerCoreRatio = &[]float64{0.5, 0.34}
	m.Cpu.IowaitRatio = nullable.NewNullableWithValue(0.01)
	// Unknown values travel as null, not as zero or a missing field.
	m.Cpu.StealRatio = nullable.NewNullNullable[float64]()
	m.Memory.TotalBytes = 8 << 30
	m.Memory.AvailableBytes = 3 << 30
	m.Memory.UsedBytes = 5 << 30
	m.Memory.CachedBytes = nullable.NewNullNullable[int64]()
	return m
}

func TestGetMetricsHostReturnsLatestSnapshot(t *testing.T) {
	handler, token := stack(t, snapshotSource{metrics: sample(), ok: true})
	response := get(t, handler, "/v1/metrics/host", token)
	if response.Code != http.StatusOK {
		t.Fatalf("status = %d, body %s", response.Code, response.Body)
	}

	var raw struct {
		CPU map[string]any `json:"cpu"`
	}
	if err := json.Unmarshal(response.Body.Bytes(), &raw); err != nil {
		t.Fatalf("decode: %v", err)
	}
	if v, present := raw.CPU["stealRatio"]; !present || v != nil {
		t.Errorf("stealRatio = %v (present %v), want an explicit null", v, present)
	}
	var got gen.HostMetrics
	if err := json.Unmarshal(response.Body.Bytes(), &got); err != nil {
		t.Fatalf("decode: %v", err)
	}
	want := sample()
	if !got.Ts.Equal(want.Ts) || got.Cpu.UsageRatio != want.Cpu.UsageRatio || got.Memory.UsedBytes != want.Memory.UsedBytes {
		t.Errorf("got %+v, want %+v", got, want)
	}
}

func TestGetMetricsHostRequiresToken(t *testing.T) {
	handler, _ := stack(t, snapshotSource{metrics: sample(), ok: true})
	if code := get(t, handler, "/v1/metrics/host", "").Code; code != http.StatusUnauthorized {
		t.Errorf("status without token = %d, want 401", code)
	}
}

func TestGetMetricsHostBeforeFirstSampleIsUpstreamUnavailable(t *testing.T) {
	handler, token := stack(t, snapshotSource{})
	wantError(t, get(t, handler, "/v1/metrics/host", token), http.StatusServiceUnavailable, gen.UpstreamUnavailable)
}

func TestGetMetricsHostWithoutCollectorIsUnsupported(t *testing.T) {
	handler, token := stack(t, nil)
	wantError(t, get(t, handler, "/v1/metrics/host", token), http.StatusNotImplemented, gen.Unsupported)
}

func TestInfoAdvertisesHostMetricsOnlyWithCollector(t *testing.T) {
	for _, tc := range []struct {
		name   string
		source handlers.HostMetricsSource
		want   bool
	}{
		{"with collector", snapshotSource{}, true},
		{"without collector", nil, false},
	} {
		t.Run(tc.name, func(t *testing.T) {
			handler, _ := stack(t, tc.source)
			var info gen.AgentInfo
			if err := json.Unmarshal(get(t, handler, "/v1/info", "").Body.Bytes(), &info); err != nil {
				t.Fatalf("decode: %v", err)
			}
			if got := slices.Contains(info.Features, gen.AgentFeatureHostMetrics); got != tc.want {
				t.Errorf("features = %v, host_metrics present = %v, want %v", info.Features, got, tc.want)
			}
		})
	}
}

func wantError(t *testing.T, response *httptest.ResponseRecorder, status int, code gen.ErrorCode) {
	t.Helper()
	if response.Code != status {
		t.Fatalf("status = %d, want %d (body %s)", response.Code, status, response.Body)
	}
	var body gen.Error
	if err := json.Unmarshal(response.Body.Bytes(), &body); err != nil {
		t.Fatalf("decode error: %v", err)
	}
	if body.Code != code || body.RequestId == "" {
		t.Errorf("error = %+v, want code %s with a request id", body, code)
	}
}
