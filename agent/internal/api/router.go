// Package api assembles the agent's HTTP API from the generated server,
// the handlers and the middleware.
package api

import (
	"fmt"
	"log/slog"
	"net/http"
	"strconv"

	"github.com/AZAZ3LL0/samat-ssh/agent/internal/api/gen"
	"github.com/AZAZ3LL0/samat-ssh/agent/internal/api/handlers"
	"github.com/AZAZ3LL0/samat-ssh/agent/internal/api/middleware"
	"github.com/AZAZ3LL0/samat-ssh/agent/internal/auth"
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
	Logger       *slog.Logger
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
	info := gen.AgentInfo{
		AgentVersion:        deps.AgentVersion,
		ApiVersion:          apiVersion,
		MinClientApiVersion: minClientAPIVersion,
		Hostname:            deps.Hostname,
		// Features appear as their collectors land; an empty list still has to
		// serialize as [], not null.
		Features: []gen.AgentFeature{},
	}

	badRequest := func(w http.ResponseWriter, r *http.Request, _ error) {
		middleware.WriteError(w, r, http.StatusBadRequest, gen.InvalidRequest, "malformed request")
	}
	strict := gen.NewStrictHandlerWithOptions(
		handlers.New(info, deps.Auth, deps.Limiter),
		nil,
		gen.StrictHTTPServerOptions{
			RequestErrorHandlerFunc: badRequest,
			ResponseErrorHandlerFunc: func(w http.ResponseWriter, r *http.Request, err error) {
				ctx := r.Context()
				deps.Logger.ErrorContext(ctx, "handle request", "error", err, "requestId", middleware.RequestIDFrom(ctx))
				middleware.WriteError(w, r, http.StatusInternalServerError, gen.Internal, "internal error")
			},
		},
	)

	mux := http.NewServeMux()
	gen.HandlerWithOptions(strict, gen.StdHTTPServerOptions{
		BaseRouter: mux,
		Middlewares: []gen.MiddlewareFunc{
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
