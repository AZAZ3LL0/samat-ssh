// Package api assembles the agent's HTTP API from the generated server,
// the handlers and the middleware.
package api

import (
	"context"
	"fmt"
	"log/slog"
	"net/http"
	"strconv"
	"strings"
	"time"

	"github.com/AZAZ3LL0/samat-ssh/agent/internal/api/gen"
	"github.com/AZAZ3LL0/samat-ssh/agent/internal/api/handlers"
	"github.com/AZAZ3LL0/samat-ssh/agent/internal/api/middleware"
	"github.com/AZAZ3LL0/samat-ssh/agent/internal/auth"
	"github.com/AZAZ3LL0/samat-ssh/agent/internal/store"
	"github.com/AZAZ3LL0/samat-ssh/agent/internal/ws"
)

const (
	// minClientAPIVersion is the oldest app contract version this agent still serves.
	minClientAPIVersion = 1
	maxRequestBody      = 1 << 20
)

// Deps are the collaborators of the HTTP API.
type Deps struct {
	AgentVersion string
	Hostname     string
	Auth         *auth.Service
	Limiter      *auth.Limiter
	// Store keeps Idempotency-Key outcomes of mutations.
	Store *store.Store
	// Now is the clock of the idempotency window.
	Now func() time.Time
	Hub *ws.Hub
	// HostMetrics serves GET /v1/metrics/host; nil when the host cannot be measured.
	HostMetrics handlers.HostMetricsSource
	Logger      *slog.Logger
}

// NewHandler returns the handler serving every /v1 endpoint.
func NewHandler(deps Deps) (http.Handler, error) {
	spec, err := gen.GetSpec()
	if err != nil {
		return nil, fmt.Errorf("load embedded contract: %w", err)
	}
	// The contract version is the core version the agent reports as apiVersion.
	apiVersion, err := strconv.Atoi(spec.Info.Version)
	if err != nil {
		return nil, fmt.Errorf("contract version %q is not an integer: %w", spec.Info.Version, err)
	}
	// An empty list still has to serialize as [], not null.
	features := []gen.AgentFeature{}
	if deps.HostMetrics != nil {
		features = append(features, gen.AgentFeatureHostMetrics)
	}
	info := gen.AgentInfo{
		AgentVersion:        deps.AgentVersion,
		ApiVersion:          apiVersion,
		MinClientApiVersion: minClientAPIVersion,
		Hostname:            deps.Hostname,
		Features:            features,
	}

	badRequest := func(w http.ResponseWriter, r *http.Request, _ error) {
		middleware.WriteError(w, r, http.StatusBadRequest, gen.InvalidRequest, "malformed request")
	}
	// The strict interface cannot take over the connection, so the upgrade
	// happens here, after the auth middleware has accepted the token.
	upgrade := func(next gen.StrictHandlerFunc, operationID string) gen.StrictHandlerFunc {
		if operationID != "ConnectWebSocket" {
			return next
		}
		return func(ctx context.Context, w http.ResponseWriter, r *http.Request, _ any) (any, error) {
			if !strings.EqualFold(r.Header.Get("Upgrade"), "websocket") {
				middleware.WriteError(w, r, http.StatusBadRequest, gen.InvalidRequest, "websocket upgrade required")
				return nil, nil
			}
			deps.Hub.Handle(w, r, middleware.RequestIDFrom(ctx))
			return nil, nil
		}
	}
	strict := gen.NewStrictHandlerWithOptions(
		handlers.New(info, deps.Auth, deps.Limiter, deps.HostMetrics),
		[]gen.StrictMiddlewareFunc{upgrade},
		gen.StrictHTTPServerOptions{
			RequestErrorHandlerFunc: badRequest,
			ResponseErrorHandlerFunc: func(w http.ResponseWriter, r *http.Request, err error) {
				ctx := r.Context()
				deps.Logger.ErrorContext(ctx, "handle request", "error", err, "requestId", middleware.RequestIDFrom(ctx))
				middleware.WriteError(w, r, http.StatusInternalServerError, gen.Internal, "internal error")
			},
		},
	)

	idempotent := middleware.IdempotentOperations(spec)
	replay := middleware.Idempotency(deps.Store, deps.Now, deps.Logger)
	onlyMutations := func(next http.Handler) http.Handler {
		wrapped := replay(next)
		return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			if idempotent[r.Pattern] {
				wrapped.ServeHTTP(w, r)
				return
			}
			next.ServeHTTP(w, r)
		})
	}

	mux := http.NewServeMux()
	gen.HandlerWithOptions(strict, gen.StdHTTPServerOptions{
		BaseRouter: mux,
		// The last middleware runs first: authorization, then replay of a known key.
		Middlewares: []gen.MiddlewareFunc{
			onlyMutations,
			middleware.Auth(deps.Auth, deps.Limiter, middleware.PublicOperations(spec), deps.Logger),
		},
		ErrorHandlerFunc: badRequest,
	})
	// Without a catch-all the mux answers unknown routes in plain text, outside the contract.
	mux.HandleFunc("/", func(w http.ResponseWriter, r *http.Request) {
		middleware.WriteError(w, r, http.StatusNotFound, gen.NotFound, "no such endpoint")
	})
	return middleware.RequestID(http.MaxBytesHandler(mux, maxRequestBody)), nil
}
