package handlers

import (
	"context"
	"net/http"

	"github.com/AZAZ3LL0/samat-ssh/agent/internal/api/gen"
	"github.com/AZAZ3LL0/samat-ssh/agent/internal/api/middleware"
)

// HostMetricsSource holds the latest host snapshot; host.Collector implements it.
type HostMetricsSource interface {
	Latest() (gen.HostMetrics, bool)
}

// GetMetricsHost returns the latest host snapshot.
func (s *Server) GetMetricsHost(ctx context.Context, _ gen.GetMetricsHostRequestObject) (gen.GetMetricsHostResponseObject, error) {
	if s.hostMetrics == nil {
		return gen.GetMetricsHostdefaultJSONResponse{
			Body:       middleware.NewError(ctx, gen.Unsupported, "host metrics are not available on this server"),
			Headers:    errorHeaders(ctx),
			StatusCode: http.StatusNotImplemented,
		}, nil
	}
	metrics, ok := s.hostMetrics.Latest()
	if !ok {
		// Only in the first second after start, or while /proc is unreadable.
		return gen.GetMetricsHostdefaultJSONResponse{
			Body:       middleware.NewError(ctx, gen.UpstreamUnavailable, "no host metrics sample yet"),
			Headers:    errorHeaders(ctx),
			StatusCode: http.StatusServiceUnavailable,
		}, nil
	}
	return gen.GetMetricsHost200JSONResponse{
		Body:    metrics,
		Headers: gen.GetMetricsHost200ResponseHeaders{XRequestId: middleware.RequestIDFrom(ctx)},
	}, nil
}
