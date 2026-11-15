package handlers

import (
	"context"

	"github.com/AZAZ3LL0/samat-ssh/agent/internal/api/gen"
	"github.com/AZAZ3LL0/samat-ssh/agent/internal/api/middleware"
)

// GetInfo reports agent versions, hostname and supported features.
func (s *Server) GetInfo(ctx context.Context, _ gen.GetInfoRequestObject) (gen.GetInfoResponseObject, error) {
	return gen.GetInfo200JSONResponse{
		Body:    s.info,
		Headers: gen.GetInfo200ResponseHeaders{XRequestId: middleware.RequestIDFrom(ctx)},
	}, nil
}
