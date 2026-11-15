package middleware

import (
	"bytes"
	"crypto/sha256"
	"errors"
	"io"
	"log/slog"
	"net/http"
	"sync"
	"time"

	"github.com/google/uuid"

	"github.com/AZAZ3LL0/samat-ssh/agent/internal/api/gen"
	"github.com/AZAZ3LL0/samat-ssh/agent/internal/store"
)

const (
	// IdempotencyKeyHeader carries the client-generated key of a mutation.
	IdempotencyKeyHeader = "Idempotency-Key"
	// IdempotencyTTL is how long a stored outcome is replayed.
	IdempotencyTTL = 24 * time.Hour

	maxMutationBody = 1 << 20
)

// Idempotency makes a mutating endpoint safe to retry: a repeat of the same
// key and body replays the stored response without running the handler again.
func Idempotency(st *store.Store, now func() time.Time, logger *slog.Logger) func(http.Handler) http.Handler {
	locks := &keyLocks{held: make(map[string]*keyLock)}
	return func(next http.Handler) http.Handler {
		return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			ctx := r.Context()
			key := r.Header.Get(IdempotencyKeyHeader)
			if id, err := uuid.Parse(key); err != nil || id.Version() != 4 {
				WriteError(w, r, http.StatusBadRequest, gen.InvalidRequest, IdempotencyKeyHeader+" must be a UUID v4")
				return
			}
			body, err := io.ReadAll(http.MaxBytesReader(w, r.Body, maxMutationBody))
			if err != nil {
				WriteError(w, r, http.StatusBadRequest, gen.InvalidRequest, "unreadable request body")
				return
			}
			r.Body = io.NopCloser(bytes.NewReader(body))
			requestHash := hashRequest(r.Method, r.URL.Path, body)

			// A retry racing the original must wait for its outcome instead of
			// running the effect a second time.
			unlock := locks.lock(key)
			defer unlock()

			record, err := st.GetIdempotency(ctx, key)
			switch {
			case err == nil && now().Sub(record.CreatedAt) < IdempotencyTTL:
				if !bytes.Equal(record.RequestHash, requestHash) {
					WriteError(w, r, http.StatusConflict, gen.IdempotencyConflict, "key was used with a different request")
					return
				}
				w.Header().Set("Content-Type", "application/json")
				w.WriteHeader(record.StatusCode)
				_, _ = w.Write(record.Response)
				return
			case err != nil && !errors.Is(err, store.ErrNotFound):
				logger.ErrorContext(ctx, "read idempotency record", "error", err, "requestId", RequestIDFrom(ctx))
				WriteError(w, r, http.StatusInternalServerError, gen.Internal, "idempotency check failed")
				return
			}

			recorder := &responseRecorder{ResponseWriter: w, status: http.StatusOK}
			next.ServeHTTP(recorder, r)

			// A server error says nothing about whether the effect happened;
			// leaving it unrecorded lets the client retry with the same key.
			if recorder.status >= http.StatusInternalServerError {
				return
			}
			err = st.PutIdempotency(ctx, store.IdempotencyRecord{
				Key:         key,
				RequestHash: requestHash,
				StatusCode:  recorder.status,
				Response:    recorder.body.Bytes(),
				CreatedAt:   now(),
			})
			if err != nil {
				logger.ErrorContext(ctx, "store idempotency record", "error", err, "requestId", RequestIDFrom(ctx))
			}
		})
	}
}

func hashRequest(method, path string, body []byte) []byte {
	h := sha256.New()
	h.Write([]byte(method))
	h.Write([]byte{0})
	h.Write([]byte(path))
	h.Write([]byte{0})
	h.Write(body)
	return h.Sum(nil)
}

type responseRecorder struct {
	http.ResponseWriter
	status int
	body   bytes.Buffer
}

func (r *responseRecorder) WriteHeader(status int) {
	r.status = status
	r.ResponseWriter.WriteHeader(status)
}

func (r *responseRecorder) Write(p []byte) (int, error) {
	r.body.Write(p)
	return r.ResponseWriter.Write(p)
}

// keyLocks serializes requests sharing an idempotency key.
type keyLocks struct {
	mu   sync.Mutex
	held map[string]*keyLock
}

type keyLock struct {
	mu      sync.Mutex
	waiters int
}

func (k *keyLocks) lock(key string) (unlock func()) {
	k.mu.Lock()
	lock, ok := k.held[key]
	if !ok {
		lock = &keyLock{}
		k.held[key] = lock
	}
	lock.waiters++
	k.mu.Unlock()

	lock.mu.Lock()
	return func() {
		lock.mu.Unlock()
		k.mu.Lock()
		lock.waiters--
		if lock.waiters == 0 {
			delete(k.held, key)
		}
		k.mu.Unlock()
	}
}
