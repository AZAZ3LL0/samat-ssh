package middleware

import (
	"context"
	"errors"
	"log/slog"
	"net"
	"net/http"
	"strings"

	"github.com/getkin/kin-openapi/openapi3"

	"github.com/AZAZ3LL0/samat-ssh/agent/internal/api/gen"
	"github.com/AZAZ3LL0/samat-ssh/agent/internal/auth"
)

// PublicOperations returns the mux patterns ("GET /v1/info") of the operations
// the contract declares with `security: []`. Deriving the set from the
// contract keeps a new endpoint protected unless the contract says otherwise.
func PublicOperations(spec *openapi3.T) map[string]bool {
	public := make(map[string]bool)
	for path, item := range spec.Paths.Map() {
		for method, operation := range item.Operations() {
			if operation.Security != nil && len(*operation.Security) == 0 {
				public[method+" "+path] = true
			}
		}
	}
	return public
}

type clientAddrKey struct{}

// ClientAddrFrom returns the peer address recorded by Auth.
func ClientAddrFrom(ctx context.Context) string {
	addr, _ := ctx.Value(clientAddrKey{}).(string)
	return addr
}

// Auth requires a valid bearer token on every operation outside public and
// blocks addresses that keep failing. It records the peer address in the
// context for all operations, because the public pairing endpoint feeds the
// same limiter.
func Auth(service *auth.Service, limiter *auth.Limiter, public map[string]bool, logger *slog.Logger) func(http.Handler) http.Handler {
	return func(next http.Handler) http.Handler {
		return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			addr := clientAddr(r)
			r = r.WithContext(context.WithValue(r.Context(), clientAddrKey{}, addr))
			if public[r.Pattern] {
				next.ServeHTTP(w, r)
				return
			}
			if limiter.Blocked(addr) {
				WriteError(w, r, http.StatusTooManyRequests, gen.RateLimited, "too many failed authorization attempts")
				return
			}
			token, ok := strings.CutPrefix(r.Header.Get("Authorization"), "Bearer ")
			if !ok || token == "" {
				limiter.Fail(addr)
				WriteError(w, r, http.StatusUnauthorized, gen.Unauthorized, "missing bearer token")
				return
			}
			_, err := service.Authenticate(r.Context(), token)
			if errors.Is(err, auth.ErrInvalidToken) {
				limiter.Fail(addr)
				WriteError(w, r, http.StatusUnauthorized, gen.Unauthorized, "invalid or revoked token")
				return
			}
			if err != nil {
				logger.ErrorContext(r.Context(), "authenticate", "error", err, "requestId", RequestIDFrom(r.Context()))
				WriteError(w, r, http.StatusInternalServerError, gen.Internal, "authentication failed")
				return
			}
			next.ServeHTTP(w, r)
		})
	}
}

// clientAddr is the peer address without the port. The agent terminates TLS
// itself, so forwarding headers are not trusted.
func clientAddr(r *http.Request) string {
	host, _, err := net.SplitHostPort(r.RemoteAddr)
	if err != nil {
		return r.RemoteAddr
	}
	return host
}
