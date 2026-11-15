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
	info    gen.AgentInfo
	auth    *auth.Service
	limiter *auth.Limiter
}

var _ gen.StrictServerInterface = (*Server)(nil)

// New returns a Server answering GET /v1/info with info.
func New(info gen.AgentInfo, service *auth.Service, limiter *auth.Limiter) *Server {
	return &Server{info: info, auth: service, limiter: limiter}
}

// GetMetricsHost is not served until the host collector exists.
func (s *Server) GetMetricsHost(ctx context.Context, _ gen.GetMetricsHostRequestObject) (gen.GetMetricsHostResponseObject, error) {
	return gen.GetMetricsHostdefaultJSONResponse{
		Body:       middleware.NewError(ctx, gen.Unsupported, "host metrics are not available in this agent build"),
		Headers:    errorHeaders(ctx),
		StatusCode: http.StatusNotImplemented,
	}, nil
}

// ConnectWebSocket is not served until the WebSocket hub exists.
func (s *Server) ConnectWebSocket(ctx context.Context, _ gen.ConnectWebSocketRequestObject) (gen.ConnectWebSocketResponseObject, error) {
	return gen.ConnectWebSocketdefaultJSONResponse{
		Body:       middleware.NewError(ctx, gen.Unsupported, "websocket is not available in this agent build"),
		Headers:    errorHeaders(ctx),
		StatusCode: http.StatusNotImplemented,
	}, nil
}

// The generated response writers overwrite X-Request-Id with the value from
// the response object, so every response has to repeat the request's id.
func errorHeaders(ctx context.Context) gen.ErrorResponseHeaders {
	return gen.ErrorResponseHeaders{XRequestId: middleware.RequestIDFrom(ctx)}
}
