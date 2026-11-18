// Package handlers implements the generated strict server interface.
package handlers

import (
	"context"
	"net/http"

	"github.com/AZAZ3LL0/samat-ssh/agent/internal/api/gen"
	"github.com/AZAZ3LL0/samat-ssh/agent/internal/api/middleware"
	"github.com/AZAZ3LL0/samat-ssh/agent/internal/auth"
)

// Server implements gen.StrictServerInterface.
type Server struct {
	info        gen.AgentInfo
	auth        *auth.Service
	limiter     *auth.Limiter
	hostMetrics HostMetricsSource
}

var _ gen.StrictServerInterface = (*Server)(nil)

// New returns a Server answering GET /v1/info with info. A nil hostMetrics
// means the host cannot be measured, and GET /v1/metrics/host says so.
func New(info gen.AgentInfo, service *auth.Service, limiter *auth.Limiter, hostMetrics HostMetricsSource) *Server {
	return &Server{info: info, auth: service, limiter: limiter, hostMetrics: hostMetrics}
}

// ConnectWebSocket exists to satisfy the generated interface: the router
// upgrades the connection before a strict handler can run.
func (s *Server) ConnectWebSocket(ctx context.Context, _ gen.ConnectWebSocketRequestObject) (gen.ConnectWebSocketResponseObject, error) {
	return gen.ConnectWebSocketdefaultJSONResponse{
		Body:       middleware.NewError(ctx, gen.Internal, "websocket upgrade was not handled"),
		Headers:    errorHeaders(ctx),
		StatusCode: http.StatusInternalServerError,
	}, nil
}

// The generated response writers overwrite X-Request-Id with the value from
// the response object, so every response has to repeat the request's id.
func errorHeaders(ctx context.Context) gen.ErrorResponseHeaders {
	return gen.ErrorResponseHeaders{XRequestId: middleware.RequestIDFrom(ctx)}
}
