package handlers

import (
	"context"
	"errors"
	"net/http"
	"unicode/utf8"

	"github.com/AZAZ3LL0/samat-ssh/agent/internal/api/gen"
	"github.com/AZAZ3LL0/samat-ssh/agent/internal/api/middleware"
	"github.com/AZAZ3LL0/samat-ssh/agent/internal/auth"
)

const maxDeviceNameLength = 64

// Pair exchanges a one-time pairing code for a device token.
func (s *Server) Pair(ctx context.Context, request gen.PairRequestObject) (gen.PairResponseObject, error) {
	addr := middleware.ClientAddrFrom(ctx)
	if s.limiter.Blocked(addr) {
		return pairError(ctx, http.StatusTooManyRequests, gen.RateLimited, "too many failed pairing attempts"), nil
	}
	body := request.Body
	if body == nil || body.Code == "" {
		return pairError(ctx, http.StatusBadRequest, gen.InvalidRequest, "code is required"), nil
	}
	if length := utf8.RuneCountInString(body.DeviceName); length == 0 || length > maxDeviceNameLength {
		return pairError(ctx, http.StatusBadRequest, gen.InvalidRequest, "deviceName must be 1 to 64 characters"), nil
	}

	token, tokenID, err := s.auth.Pair(ctx, body.Code, body.DeviceName)
	if errors.Is(err, auth.ErrInvalidCode) {
		// Every miss counts toward the limit. Expired and used codes get their own
		// answer so the user knows to run `pulse-agent pair` again; telling them
		// apart needs the code itself, so guessing gains nothing from it.
		s.limiter.Fail(addr)
		switch {
		case errors.Is(err, auth.ErrCodeExpired):
			return pairError(ctx, http.StatusGone, gen.PairingCodeExpired, "pairing code expired"), nil
		case errors.Is(err, auth.ErrCodeUsed):
			return pairError(ctx, http.StatusGone, gen.PairingCodeUsed, "pairing code already used"), nil
		default:
			return pairError(ctx, http.StatusUnauthorized, gen.Unauthorized, "pairing code is invalid"), nil
		}
	}
	if err != nil {
		return nil, err
	}
	return gen.Pair200JSONResponse{
		Body:    gen.PairResponse{Token: token, TokenId: tokenID},
		Headers: gen.Pair200ResponseHeaders{XRequestId: middleware.RequestIDFrom(ctx)},
	}, nil
}

func pairError(ctx context.Context, status int, code gen.ErrorCode, message string) gen.PairdefaultJSONResponse {
	return gen.PairdefaultJSONResponse{
		Body:       middleware.NewError(ctx, code, message),
		Headers:    errorHeaders(ctx),
		StatusCode: status,
	}
}
