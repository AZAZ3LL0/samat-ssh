package auth

import (
	"context"
	"crypto/rand"
	"crypto/sha256"
	"encoding/base32"
	"encoding/base64"
	"encoding/hex"
	"errors"
	"fmt"
	"strings"
	"time"

	"github.com/AZAZ3LL0/samat-ssh/agent/internal/store"
)

const (
	// PairingCodeTTL is how long a pairing code stays valid.
	PairingCodeTTL = 10 * time.Minute

	pairingCodeBytes = 5 // 8 base32 characters
	tokenBytes       = 32
	tokenIDBytes     = 8
	// Writing last_used_at on every request would turn each read into a
	// database write; minute precision is enough for `tokens list`.
	touchInterval = time.Minute
)

var (
	// ErrInvalidCode reports a pairing code that cannot pair. Unknown codes
	// return it as is; expired and used codes return the errors below, which wrap it.
	ErrInvalidCode = errors.New("auth: invalid pairing code")
	// ErrCodeExpired reports a pairing code whose ten minutes are over.
	ErrCodeExpired = fmt.Errorf("%w: expired", ErrInvalidCode)
	// ErrCodeUsed reports a pairing code that already paired a device.
	ErrCodeUsed = fmt.Errorf("%w: already used", ErrInvalidCode)
	// ErrInvalidToken reports a token that is unknown or revoked.
	ErrInvalidToken = errors.New("auth: invalid token")
	// ErrTokenNotFound reports a revocation of an unknown or already revoked token.
	ErrTokenNotFound = errors.New("auth: token not found")
)

// Service issues pairing codes and device tokens. Only SHA-256 hashes of
// either reach the database.
type Service struct {
	store *store.Store
	now   func() time.Time
}

// NewService returns a Service reading time from now.
func NewService(st *store.Store, now func() time.Time) *Service {
	return &Service{store: st, now: now}
}

// NewPairingCode creates a one-time pairing code.
func (s *Service) NewPairingCode(ctx context.Context) (code string, expiresAt time.Time, err error) {
	raw := make([]byte, pairingCodeBytes)
	if _, err := rand.Read(raw); err != nil {
		return "", time.Time{}, fmt.Errorf("generate pairing code: %w", err)
	}
	code = base32.StdEncoding.EncodeToString(raw)
	now := s.now()
	expiresAt = now.Add(PairingCodeTTL)
	if err := s.store.InsertPairingCode(ctx, hash(code), now, expiresAt); err != nil {
		return "", time.Time{}, err
	}
	return code, expiresAt, nil
}

// Pair exchanges a pairing code for a new device token.
func (s *Service) Pair(ctx context.Context, code, deviceName string) (token, tokenID string, err error) {
	rawToken := make([]byte, tokenBytes)
	if _, err := rand.Read(rawToken); err != nil {
		return "", "", fmt.Errorf("generate token: %w", err)
	}
	rawID := make([]byte, tokenIDBytes)
	if _, err := rand.Read(rawID); err != nil {
		return "", "", fmt.Errorf("generate token id: %w", err)
	}
	token = base64.RawURLEncoding.EncodeToString(rawToken)
	tokenID = hex.EncodeToString(rawID)

	// Codes are typed by hand in the manual flow, so case and stray spaces are forgiven.
	normalized := strings.ToUpper(strings.TrimSpace(code))
	err = s.store.PairDevice(ctx, hash(normalized), tokenID, deviceName, hash(token), s.now())
	switch {
	case errors.Is(err, store.ErrPairingCodeUsed):
		return "", "", ErrCodeUsed
	case errors.Is(err, store.ErrPairingCodeExpired):
		return "", "", ErrCodeExpired
	case errors.Is(err, store.ErrPairingCodeInvalid):
		return "", "", ErrInvalidCode
	}
	if err != nil {
		return "", "", err
	}
	return token, tokenID, nil
}

// Authenticate resolves a bearer token to its record.
func (s *Service) Authenticate(ctx context.Context, token string) (store.Token, error) {
	record, err := s.store.TokenByHash(ctx, hash(token))
	if errors.Is(err, store.ErrNotFound) {
		return store.Token{}, ErrInvalidToken
	}
	if err != nil {
		return store.Token{}, err
	}
	if record.RevokedAt != nil {
		return store.Token{}, ErrInvalidToken
	}
	now := s.now()
	if record.LastUsedAt == nil || now.Sub(*record.LastUsedAt) >= touchInterval {
		if err := s.store.TouchToken(ctx, record.ID, now); err != nil {
			return store.Token{}, err
		}
	}
	return record, nil
}

// Tokens lists every device token, oldest first.
func (s *Service) Tokens(ctx context.Context) ([]store.Token, error) {
	return s.store.ListTokens(ctx)
}

// Revoke revokes the token with the given id.
func (s *Service) Revoke(ctx context.Context, tokenID string) error {
	err := s.store.RevokeToken(ctx, tokenID, s.now())
	if errors.Is(err, store.ErrNotFound) {
		return ErrTokenNotFound
	}
	return err
}

func hash(secret string) []byte {
	sum := sha256.Sum256([]byte(secret))
	return sum[:]
}
