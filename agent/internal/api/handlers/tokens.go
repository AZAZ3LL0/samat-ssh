package handlers

import (
	"context"
	"encoding/base64"
	"errors"
	"net/http"
	"slices"
	"strconv"
	"strings"
	"time"

	"github.com/oapi-codegen/nullable"

	"github.com/AZAZ3LL0/samat-ssh/agent/internal/api/apitime"
	"github.com/AZAZ3LL0/samat-ssh/agent/internal/api/gen"
	"github.com/AZAZ3LL0/samat-ssh/agent/internal/api/middleware"
	"github.com/AZAZ3LL0/samat-ssh/agent/internal/auth"
	"github.com/AZAZ3LL0/samat-ssh/agent/internal/store"
)

const defaultPageLimit = 100

// ListTokens lists the devices that may still call the agent, oldest first.
func (s *Server) ListTokens(ctx context.Context, request gen.ListTokensRequestObject) (gen.ListTokensResponseObject, error) {
	limit := defaultPageLimit
	if request.Params.Limit != nil {
		limit = *request.Params.Limit
	}
	if limit < 1 || limit > 1000 {
		return listTokensError(ctx, http.StatusBadRequest, gen.InvalidRequest, "limit must be 1 to 1000"), nil
	}
	var after *tokenCursor
	if request.Params.Cursor != nil {
		cursor, ok := parseTokenCursor(*request.Params.Cursor)
		if !ok {
			return listTokensError(ctx, http.StatusBadRequest, gen.InvalidRequest, "malformed cursor"), nil
		}
		after = &cursor
	}

	all, err := s.auth.Tokens(ctx)
	if err != nil {
		return nil, err
	}
	caller, _ := middleware.TokenFrom(ctx)
	var last store.Token
	page := gen.DeviceTokenPage{Items: []gen.DeviceToken{}, NextCursor: nullable.NewNullNullable[string]()}
	for _, token := range all {
		if token.RevokedAt != nil || (after != nil && !after.before(token)) {
			continue
		}
		if len(page.Items) == limit {
			page.NextCursor = nullable.NewNullableWithValue(cursorOf(last))
			break
		}
		lastUsedAt := nullable.NewNullNullable[apitime.Time]()
		if token.LastUsedAt != nil {
			lastUsedAt = nullable.NewNullableWithValue(apitime.New(*token.LastUsedAt))
		}
		page.Items = append(page.Items, gen.DeviceToken{
			Id:         token.ID,
			DeviceName: token.DeviceName,
			CreatedAt:  apitime.New(token.CreatedAt),
			LastUsedAt: lastUsedAt,
			Current:    token.ID == caller.ID,
		})
		last = token
	}
	return gen.ListTokens200JSONResponse{
		Body:    page,
		Headers: gen.ListTokens200ResponseHeaders{XRequestId: middleware.RequestIDFrom(ctx)},
	}, nil
}

// RevokeToken revokes another device. A token revoked before counts as done,
// so a retry with a fresh key after a lost response still succeeds.
func (s *Server) RevokeToken(ctx context.Context, request gen.RevokeTokenRequestObject) (gen.RevokeTokenResponseObject, error) {
	err := s.auth.Revoke(ctx, request.Id)
	if errors.Is(err, auth.ErrTokenNotFound) {
		all, listErr := s.auth.Tokens(ctx)
		if listErr != nil {
			return nil, listErr
		}
		if !slices.ContainsFunc(all, func(t store.Token) bool { return t.ID == request.Id }) {
			return gen.RevokeTokendefaultJSONResponse{
				Body:       middleware.NewError(ctx, gen.NotFound, "no such token"),
				Headers:    errorHeaders(ctx),
				StatusCode: http.StatusNotFound,
			}, nil
		}
		err = nil
	}
	if err != nil {
		return nil, err
	}
	return gen.RevokeToken204Response{
		Headers: gen.NoContentResponseHeaders{XRequestId: middleware.RequestIDFrom(ctx)},
	}, nil
}

// RevokeOwnToken unpairs the calling device.
func (s *Server) RevokeOwnToken(ctx context.Context, _ gen.RevokeOwnTokenRequestObject) (gen.RevokeOwnTokenResponseObject, error) {
	caller, ok := middleware.TokenFrom(ctx)
	if !ok {
		return nil, errors.New("revoke own token: no token in the request context")
	}
	if err := s.auth.Revoke(ctx, caller.ID); err != nil {
		return nil, err
	}
	return gen.RevokeOwnToken204Response{
		Headers: gen.NoContentResponseHeaders{XRequestId: middleware.RequestIDFrom(ctx)},
	}, nil
}

func listTokensError(ctx context.Context, status int, code gen.ErrorCode, message string) gen.ListTokensdefaultJSONResponse {
	return gen.ListTokensdefaultJSONResponse{
		Body:       middleware.NewError(ctx, code, message),
		Headers:    errorHeaders(ctx),
		StatusCode: status,
	}
}

// tokenCursor is the position after the last token of a page, in list order
// (created_at, id). A position rather than an id keeps paging stable when
// that token is revoked between pages.
type tokenCursor struct {
	createdAt time.Time
	id        string
}

func cursorOf(token store.Token) string {
	raw := strconv.FormatInt(token.CreatedAt.UnixMilli(), 10) + ":" + token.ID
	return base64.RawURLEncoding.EncodeToString([]byte(raw))
}

func parseTokenCursor(value string) (tokenCursor, bool) {
	raw, err := base64.RawURLEncoding.DecodeString(value)
	if err != nil {
		return tokenCursor{}, false
	}
	millis, id, ok := strings.Cut(string(raw), ":")
	if !ok || id == "" {
		return tokenCursor{}, false
	}
	ms, err := strconv.ParseInt(millis, 10, 64)
	if err != nil {
		return tokenCursor{}, false
	}
	return tokenCursor{createdAt: time.UnixMilli(ms).UTC(), id: id}, true
}

// before reports whether the cursor position comes before token in list order.
func (c tokenCursor) before(token store.Token) bool {
	if !token.CreatedAt.Equal(c.createdAt) {
		return token.CreatedAt.After(c.createdAt)
	}
	return token.ID > c.id
}
