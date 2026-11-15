// Package middleware holds the HTTP middleware shared by every endpoint.
package middleware

import (
	"context"
	"crypto/rand"
	"encoding/json"
	"net/http"

	"github.com/AZAZ3LL0/samat-ssh/agent/internal/api/gen"
)

// RequestIDHeader is present on every response.
const RequestIDHeader = "X-Request-Id"

type requestIDKey struct{}

// RequestID assigns each request an id, exposes it in the context and sets it
// on the response before any handler runs, so early exits (404, auth
// failure) carry it too.
func RequestID(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		id := rand.Text()
		w.Header().Set(RequestIDHeader, id)
		next.ServeHTTP(w, r.WithContext(context.WithValue(r.Context(), requestIDKey{}, id)))
	})
}

// RequestIDFrom returns the id assigned by RequestID, or "" outside a request.
func RequestIDFrom(ctx context.Context) string {
	id, _ := ctx.Value(requestIDKey{}).(string)
	return id
}

// NewError builds the contract Error for the request in ctx.
func NewError(ctx context.Context, code gen.ErrorCode, message string) gen.Error {
	return gen.Error{Code: code, Message: message, RequestId: RequestIDFrom(ctx)}
}

// WriteError writes the contract Error. It serves the paths that never reach
// a generated handler: middleware rejections, unknown routes, malformed bodies.
func WriteError(w http.ResponseWriter, r *http.Request, status int, code gen.ErrorCode, message string) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	_ = json.NewEncoder(w).Encode(NewError(r.Context(), code, message))
}
