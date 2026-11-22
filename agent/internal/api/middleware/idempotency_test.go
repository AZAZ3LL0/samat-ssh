package middleware_test

import (
	"context"
	"encoding/json"
	"fmt"
	"io"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"path/filepath"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	"github.com/AZAZ3LL0/samat-ssh/agent/internal/api/gen"
	"github.com/AZAZ3LL0/samat-ssh/agent/internal/api/middleware"
	"github.com/AZAZ3LL0/samat-ssh/agent/internal/store"
)

const (
	keyA = "0b5f4c1e-3d2a-4f6b-8c7d-9e0f1a2b3c4d"
	keyB = "7c9e6679-7425-40de-944b-e07fc1f90ae7"
)

// mutation is a stand-in for a mutating endpoint: every call that reaches it
// is one side effect, and the response differs per effect so a replay is
// distinguishable from a second execution.
type mutation struct {
	effects atomic.Int64
	status  atomic.Int64
	delay   time.Duration
}

func (m *mutation) ServeHTTP(w http.ResponseWriter, _ *http.Request) {
	time.Sleep(m.delay)
	n := m.effects.Add(1)
	status := int(m.status.Load())
	if status == 0 {
		status = http.StatusAccepted
	}
	if status == http.StatusNoContent {
		w.WriteHeader(status)
		return
	}
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	_, _ = fmt.Fprintf(w, `{"effect":%d}`, n)
}

type idempotencyFixture struct {
	handler  http.Handler
	mutation *mutation
	store    *store.Store
	now      time.Time
}

func newIdempotencyFixture(t *testing.T) *idempotencyFixture {
	t.Helper()
	st, err := store.Open(context.Background(), filepath.Join(t.TempDir(), "pulse.db"))
	if err != nil {
		t.Fatalf("open store: %v", err)
	}
	t.Cleanup(func() { _ = st.Close() })
	f := &idempotencyFixture{mutation: &mutation{}, store: st, now: time.Date(2026, 11, 15, 10, 0, 0, 0, time.UTC)}
	logger := slog.New(slog.NewTextHandler(io.Discard, nil))
	f.handler = middleware.RequestID(
		middleware.Idempotency(st, func() time.Time { return f.now }, logger)(f.mutation))
	return f
}

func (f *idempotencyFixture) post(key, body string) *httptest.ResponseRecorder {
	request := httptest.NewRequest(http.MethodPost, "/v1/actions", strings.NewReader(body))
	if key != "" {
		request.Header.Set(middleware.IdempotencyKeyHeader, key)
	}
	recorder := httptest.NewRecorder()
	f.handler.ServeHTTP(recorder, request)
	return recorder
}

func wantError(t *testing.T, response *httptest.ResponseRecorder, status int, code gen.ErrorCode) {
	t.Helper()
	if response.Code != status {
		t.Fatalf("status = %d, want %d (body %s)", response.Code, status, response.Body)
	}
	var body gen.Error
	if err := json.Unmarshal(response.Body.Bytes(), &body); err != nil {
		t.Fatalf("body %q is not an Error: %v", response.Body, err)
	}
	if body.Code != code {
		t.Errorf("error code = %q, want %q", body.Code, code)
	}
	if body.RequestId == "" || body.RequestId != response.Header().Get(middleware.RequestIDHeader) {
		t.Errorf("requestId %q does not match header %q", body.RequestId, response.Header().Get(middleware.RequestIDHeader))
	}
}

func TestRepeatWithSameKeyAndBodyHasOneEffect(t *testing.T) {
	f := newIdempotencyFixture(t)
	first := f.post(keyA, `{"kind":"restart","target":"compose:web"}`)
	second := f.post(keyA, `{"kind":"restart","target":"compose:web"}`)

	if got := f.mutation.effects.Load(); got != 1 {
		t.Fatalf("effects = %d, want exactly 1", got)
	}
	if first.Code != second.Code || first.Body.String() != second.Body.String() {
		t.Errorf("replay differs: %d %s, then %d %s", first.Code, first.Body, second.Code, second.Body)
	}
	if got := second.Header().Get("Content-Type"); got != "application/json" {
		t.Errorf("replay Content-Type = %q, want application/json", got)
	}
}

func TestRepeatOfResponseWithoutBodyHasOneEffect(t *testing.T) {
	f := newIdempotencyFixture(t)
	f.mutation.status.Store(http.StatusNoContent)
	first := f.post(keyA, `{}`)
	second := f.post(keyA, `{}`)

	if got := f.mutation.effects.Load(); got != 1 {
		t.Fatalf("effects = %d, want exactly 1", got)
	}
	if first.Code != http.StatusNoContent || second.Code != http.StatusNoContent || second.Body.Len() != 0 {
		t.Errorf("responses = %d, then %d %q; want 204 twice without a body", first.Code, second.Code, second.Body)
	}
	if got := second.Header().Get("Content-Type"); got != "" {
		t.Errorf("replay Content-Type = %q, want none for an empty body", got)
	}
	wantError(t, f.post(keyA, `{"other":true}`), http.StatusConflict, gen.IdempotencyConflict)
}

func TestSameKeyWithDifferentBodyConflicts(t *testing.T) {
	f := newIdempotencyFixture(t)
	f.post(keyA, `{"kind":"restart","target":"compose:web"}`)
	conflict := f.post(keyA, `{"kind":"stop","target":"compose:web"}`)

	wantError(t, conflict, http.StatusConflict, gen.IdempotencyConflict)
	if got := f.mutation.effects.Load(); got != 1 {
		t.Errorf("effects = %d, want 1", got)
	}
}

func TestDifferentKeysAreIndependent(t *testing.T) {
	f := newIdempotencyFixture(t)
	f.post(keyA, `{}`)
	f.post(keyB, `{}`)
	if got := f.mutation.effects.Load(); got != 2 {
		t.Errorf("effects = %d, want 2", got)
	}
}

func TestMissingOrMalformedKeyIsRejected(t *testing.T) {
	for name, key := range map[string]string{
		"missing":    "",
		"not a uuid": "restart-web-1",
		"uuid v1":    "c232ab00-9414-11ec-b3c8-9f6bdeced846",
	} {
		t.Run(name, func(t *testing.T) {
			f := newIdempotencyFixture(t)
			wantError(t, f.post(key, `{}`), http.StatusBadRequest, gen.InvalidRequest)
			if got := f.mutation.effects.Load(); got != 0 {
				t.Errorf("effects = %d, want 0", got)
			}
		})
	}
}

func TestConcurrentRetriesHaveOneEffect(t *testing.T) {
	f := newIdempotencyFixture(t)
	f.mutation.delay = 20 * time.Millisecond

	var wg sync.WaitGroup
	bodies := make([]string, 8)
	for i := range bodies {
		wg.Add(1)
		go func() {
			defer wg.Done()
			bodies[i] = f.post(keyA, `{}`).Body.String()
		}()
	}
	wg.Wait()

	if got := f.mutation.effects.Load(); got != 1 {
		t.Fatalf("effects = %d, want exactly 1", got)
	}
	for _, body := range bodies {
		if body != bodies[0] {
			t.Errorf("responses differ: %q and %q", bodies[0], body)
		}
	}
}

func TestKeyIsForgottenAfterTwentyFourHours(t *testing.T) {
	f := newIdempotencyFixture(t)
	f.post(keyA, `{}`)

	f.now = f.now.Add(24*time.Hour - time.Second)
	f.post(keyA, `{}`)
	if got := f.mutation.effects.Load(); got != 1 {
		t.Fatalf("effects within 24 hours = %d, want 1", got)
	}

	f.now = f.now.Add(time.Second)
	f.post(keyA, `{"other":true}`)
	if got := f.mutation.effects.Load(); got != 2 {
		t.Errorf("effects after 24 hours = %d, want 2", got)
	}
}

// A 5xx does not tell the client whether the effect happened, so the same key
// must be allowed to run again.
func TestServerErrorIsNotReplayed(t *testing.T) {
	f := newIdempotencyFixture(t)
	f.mutation.status.Store(http.StatusServiceUnavailable)
	f.post(keyA, `{}`)

	f.mutation.status.Store(http.StatusAccepted)
	retry := f.post(keyA, `{}`)
	if retry.Code != http.StatusAccepted {
		t.Errorf("retry status = %d, want 202", retry.Code)
	}
	if got := f.mutation.effects.Load(); got != 2 {
		t.Errorf("effects = %d, want 2", got)
	}
}

func TestPurgeDropsOnlyExpiredRecords(t *testing.T) {
	f := newIdempotencyFixture(t)
	ctx := context.Background()
	f.post(keyA, `{}`)
	f.now = f.now.Add(23 * time.Hour)
	f.post(keyB, `{}`)
	f.now = f.now.Add(2 * time.Hour)

	if err := f.store.PurgeIdempotency(ctx, f.now.Add(-middleware.IdempotencyTTL)); err != nil {
		t.Fatalf("purge: %v", err)
	}
	if _, err := f.store.GetIdempotency(ctx, keyA); err == nil {
		t.Error("record older than 24 hours survived the purge")
	}
	if _, err := f.store.GetIdempotency(ctx, keyB); err != nil {
		t.Errorf("record younger than 24 hours was purged: %v", err)
	}
}
