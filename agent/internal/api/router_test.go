package api_test

import (
	"context"
	"encoding/json"
	"io"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/AZAZ3LL0/samat-ssh/agent/internal/api"
	"github.com/AZAZ3LL0/samat-ssh/agent/internal/api/contracttest"
	"github.com/AZAZ3LL0/samat-ssh/agent/internal/api/gen"
	"github.com/AZAZ3LL0/samat-ssh/agent/internal/api/middleware"
	"github.com/AZAZ3LL0/samat-ssh/agent/internal/auth"
	"github.com/AZAZ3LL0/samat-ssh/agent/internal/store"
)

const (
	phone  = "203.0.113.10:50000"
	laptop = "203.0.113.20:50000"
)

// fixture is the full API stack. checked validates every response against the
// contract; raw is for requests the contract does not describe (unknown routes).
type fixture struct {
	t       *testing.T
	checked http.Handler
	raw     http.Handler
	auth    *auth.Service
	now     time.Time
}

func newFixture(t *testing.T) *fixture {
	t.Helper()
	st, err := store.Open(context.Background(), filepath.Join(t.TempDir(), "pulse.db"))
	if err != nil {
		t.Fatalf("open store: %v", err)
	}
	t.Cleanup(func() { _ = st.Close() })

	f := &fixture{t: t, now: time.Date(2026, 11, 15, 10, 0, 0, 0, time.UTC)}
	clock := func() time.Time { return f.now }
	f.auth = auth.NewService(st, clock)
	f.raw, err = api.NewHandler(api.Deps{
		AgentVersion: "0.3.1",
		Hostname:     "vps-1",
		Auth:         f.auth,
		Limiter:      auth.NewLimiter(clock),
		Logger:       slog.New(slog.NewTextHandler(io.Discard, nil)),
	})
	if err != nil {
		t.Fatalf("build handler: %v", err)
	}
	f.checked = contracttest.Middleware(t)(f.raw)
	return f
}

type call struct {
	method, path, body, token, from string
}

func (f *fixture) do(handler http.Handler, c call) *httptest.ResponseRecorder {
	f.t.Helper()
	var body io.Reader
	if c.body != "" {
		body = strings.NewReader(c.body)
	}
	request := httptest.NewRequest(c.method, c.path, body)
	if c.body != "" {
		request.Header.Set("Content-Type", "application/json")
	}
	if c.token != "" {
		request.Header.Set("Authorization", "Bearer "+c.token)
	}
	request.RemoteAddr = phone
	if c.from != "" {
		request.RemoteAddr = c.from
	}
	recorder := httptest.NewRecorder()
	handler.ServeHTTP(recorder, request)
	return recorder
}

func (f *fixture) get(path, token string) *httptest.ResponseRecorder {
	f.t.Helper()
	return f.do(f.checked, call{method: http.MethodGet, path: path, token: token})
}

func (f *fixture) pair(body string) *httptest.ResponseRecorder {
	f.t.Helper()
	return f.do(f.checked, call{method: http.MethodPost, path: "/v1/pair", body: body})
}

func (f *fixture) code() string {
	f.t.Helper()
	code, _, err := f.auth.NewPairingCode(context.Background())
	if err != nil {
		f.t.Fatalf("new pairing code: %v", err)
	}
	return code
}

// token pairs a device through the API and returns its token and id.
func (f *fixture) token() (token, tokenID string) {
	f.t.Helper()
	response := f.pair(`{"code":"` + f.code() + `","deviceName":"iPhone"}`)
	if response.Code != http.StatusOK {
		f.t.Fatalf("pair status = %d, body %s", response.Code, response.Body)
	}
	var body gen.PairResponse
	decode(f.t, response, &body)
	return body.Token, body.TokenId
}

func decode(t *testing.T, response *httptest.ResponseRecorder, into any) {
	t.Helper()
	if err := json.Unmarshal(response.Body.Bytes(), into); err != nil {
		t.Fatalf("decode body %q: %v", response.Body, err)
	}
}

func wantError(t *testing.T, response *httptest.ResponseRecorder, status int, code gen.ErrorCode) {
	t.Helper()
	if response.Code != status {
		t.Fatalf("status = %d, want %d (body %s)", response.Code, status, response.Body)
	}
	var body gen.Error
	decode(t, response, &body)
	if body.Code != code {
		t.Errorf("error code = %q, want %q", body.Code, code)
	}
	header := response.Header().Get(middleware.RequestIDHeader)
	if header == "" || body.RequestId != header {
		t.Errorf("requestId %q does not match X-Request-Id %q", body.RequestId, header)
	}
}

func TestInfoIsPublicAndReportsCoreVersion(t *testing.T) {
	f := newFixture(t)
	response := f.get("/v1/info", "")
	if response.Code != http.StatusOK {
		t.Fatalf("status = %d, body %s", response.Code, response.Body)
	}
	var raw map[string]any
	decode(t, response, &raw)
	want := map[string]any{"agentVersion": "0.3.1", "apiVersion": 1.0, "minClientApiVersion": 1.0, "hostname": "vps-1"}
	for key, value := range want {
		if raw[key] != value {
			t.Errorf("%s = %v, want %v", key, raw[key], value)
		}
	}
	if _, ok := raw["features"].([]any); !ok {
		t.Errorf("features = %v, want a JSON array", raw["features"])
	}
}

func TestPairExchangesCodeForWorkingToken(t *testing.T) {
	f := newFixture(t)
	token, tokenID := f.token()
	if token == "" || tokenID == "" {
		t.Fatalf("token = %q, tokenId = %q, want both set", token, tokenID)
	}
	// 501 means the request passed authorization; the endpoint itself lands later.
	wantError(t, f.get("/v1/metrics/host", token), http.StatusNotImplemented, gen.Unsupported)
}

func TestPairRejectsBadCodes(t *testing.T) {
	f := newFixture(t)

	wantError(t, f.pair(`{"code":"AAAAAAAA","deviceName":"iPhone"}`), http.StatusUnauthorized, gen.Unauthorized)

	used := f.code()
	if response := f.pair(`{"code":"` + used + `","deviceName":"iPhone"}`); response.Code != http.StatusOK {
		t.Fatalf("first use status = %d", response.Code)
	}
	wantError(t, f.pair(`{"code":"`+used+`","deviceName":"iPad"}`), http.StatusUnauthorized, gen.Unauthorized)

	expired := f.code()
	f.now = f.now.Add(10 * time.Minute)
	wantError(t, f.pair(`{"code":"`+expired+`","deviceName":"iPhone"}`), http.StatusUnauthorized, gen.Unauthorized)
}

func TestPairRejectsInvalidRequests(t *testing.T) {
	f := newFixture(t)
	code := f.code()
	for name, body := range map[string]string{
		"device name over 64": `{"code":"` + code + `","deviceName":"` + strings.Repeat("x", 65) + `"}`,
		"empty device name":   `{"code":"` + code + `","deviceName":""}`,
		"missing code":        `{"deviceName":"iPhone"}`,
		"malformed json":      `{"code":`,
	} {
		t.Run(name, func(t *testing.T) {
			wantError(t, f.pair(body), http.StatusBadRequest, gen.InvalidRequest)
		})
	}
	// None of the rejected requests may have consumed the code.
	if response := f.pair(`{"code":"` + code + `","deviceName":"` + strings.Repeat("x", 64) + `"}`); response.Code != http.StatusOK {
		t.Errorf("valid request after rejections: status = %d, body %s", response.Code, response.Body)
	}
}

func TestProtectedEndpointRequiresValidToken(t *testing.T) {
	f := newFixture(t)
	token, tokenID := f.token()

	wantError(t, f.get("/v1/metrics/host", ""), http.StatusUnauthorized, gen.Unauthorized)
	wantError(t, f.get("/v1/metrics/host", "not-a-token"), http.StatusUnauthorized, gen.Unauthorized)
	wantError(t, f.get("/v1/ws", ""), http.StatusUnauthorized, gen.Unauthorized)

	basic := httptest.NewRequest(http.MethodGet, "/v1/metrics/host", nil)
	basic.Header.Set("Authorization", "Basic "+token)
	recorder := httptest.NewRecorder()
	f.checked.ServeHTTP(recorder, basic)
	wantError(t, recorder, http.StatusUnauthorized, gen.Unauthorized)

	if err := f.auth.Revoke(context.Background(), tokenID); err != nil {
		t.Fatalf("revoke: %v", err)
	}
	wantError(t, f.get("/v1/metrics/host", token), http.StatusUnauthorized, gen.Unauthorized)
}

func TestTenFailedAuthorizationsBlockTheAddressForFiveMinutes(t *testing.T) {
	f := newFixture(t)
	token, _ := f.token()
	bad := call{method: http.MethodGet, path: "/v1/metrics/host", token: "wrong"}
	good := call{method: http.MethodGet, path: "/v1/metrics/host", token: token}

	for range 10 {
		wantError(t, f.do(f.checked, bad), http.StatusUnauthorized, gen.Unauthorized)
	}
	wantError(t, f.do(f.checked, bad), http.StatusTooManyRequests, gen.RateLimited)
	wantError(t, f.do(f.checked, good), http.StatusTooManyRequests, gen.RateLimited)

	fromLaptop := good
	fromLaptop.from = laptop
	wantError(t, f.do(f.checked, fromLaptop), http.StatusNotImplemented, gen.Unsupported)
	if response := f.get("/v1/info", ""); response.Code != http.StatusOK {
		t.Errorf("public endpoint from a blocked address: status = %d, want 200", response.Code)
	}

	f.now = f.now.Add(5 * time.Minute)
	wantError(t, f.do(f.checked, good), http.StatusNotImplemented, gen.Unsupported)
}

func TestTenWrongPairingCodesBlockTheAddress(t *testing.T) {
	f := newFixture(t)
	code := f.code()
	for range 10 {
		wantError(t, f.pair(`{"code":"AAAAAAAA","deviceName":"iPhone"}`), http.StatusUnauthorized, gen.Unauthorized)
	}
	wantError(t, f.pair(`{"code":"`+code+`","deviceName":"iPhone"}`), http.StatusTooManyRequests, gen.RateLimited)
}

func TestUnknownRouteAnswersWithContractError(t *testing.T) {
	f := newFixture(t)
	for name, c := range map[string]call{
		"unknown path": {method: http.MethodGet, path: "/v1/nope"},
		"wrong method": {method: http.MethodDelete, path: "/v1/info"},
		"root":         {method: http.MethodGet, path: "/"},
	} {
		t.Run(name, func(t *testing.T) {
			wantError(t, f.do(f.raw, c), http.StatusNotFound, gen.NotFound)
		})
	}
}

func TestEveryResponseCarriesUniqueRequestID(t *testing.T) {
	f := newFixture(t)
	token, _ := f.token()
	seen := make(map[string]bool)
	for _, c := range []call{
		{method: http.MethodGet, path: "/v1/info"},
		{method: http.MethodPost, path: "/v1/pair", body: `{"code":"` + f.code() + `","deviceName":"iPad"}`},
		{method: http.MethodPost, path: "/v1/pair", body: `{"code":"AAAAAAAA","deviceName":"iPad"}`},
		{method: http.MethodPost, path: "/v1/pair", body: `{`},
		{method: http.MethodGet, path: "/v1/metrics/host"},
		{method: http.MethodGet, path: "/v1/metrics/host", token: token},
		{method: http.MethodGet, path: "/v1/ws", token: token},
		{method: http.MethodGet, path: "/v1/nope"},
	} {
		response := f.do(f.raw, c)
		id := response.Header().Get(middleware.RequestIDHeader)
		if id == "" {
			t.Errorf("%s %s -> %d has no X-Request-Id", c.method, c.path, response.Code)
		}
		if seen[id] {
			t.Errorf("%s %s reused request id %q", c.method, c.path, id)
		}
		seen[id] = true
	}
}
