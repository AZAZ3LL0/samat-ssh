package auth

import (
	"bytes"
	"context"
	"encoding/base64"
	"errors"
	"os"
	"path/filepath"
	"regexp"
	"strings"
	"testing"
	"time"

	"github.com/AZAZ3LL0/samat-ssh/agent/internal/store"
)

type clock struct{ t time.Time }

func (c *clock) now() time.Time          { return c.t }
func (c *clock) advance(d time.Duration) { c.t = c.t.Add(d) }

func newService(t *testing.T) (*Service, *clock, string) {
	t.Helper()
	dbPath := filepath.Join(t.TempDir(), "pulse.db")
	st, err := store.Open(context.Background(), dbPath)
	if err != nil {
		t.Fatalf("open store: %v", err)
	}
	t.Cleanup(func() { _ = st.Close() })
	c := &clock{t: time.Date(2026, 11, 15, 10, 0, 0, 0, time.UTC)}
	return NewService(st, c.now), c, dbPath
}

func mustPair(t *testing.T, svc *Service) (token, tokenID string) {
	t.Helper()
	ctx := context.Background()
	code, _, err := svc.NewPairingCode(ctx)
	if err != nil {
		t.Fatalf("new pairing code: %v", err)
	}
	token, tokenID, err = svc.Pair(ctx, code, "iPhone")
	if err != nil {
		t.Fatalf("pair: %v", err)
	}
	return token, tokenID
}

func TestPairingCodeIsEightBase32CharsValidTenMinutes(t *testing.T) {
	svc, c, _ := newService(t)
	code, expiresAt, err := svc.NewPairingCode(context.Background())
	if err != nil {
		t.Fatalf("new pairing code: %v", err)
	}
	if !regexp.MustCompile(`^[A-Z2-7]{8}$`).MatchString(code) {
		t.Errorf("code %q is not 8 base32 characters", code)
	}
	if want := c.now().Add(10 * time.Minute); !expiresAt.Equal(want) {
		t.Errorf("expiresAt = %s, want %s", expiresAt, want)
	}
}

func TestPairIssuesThirtyTwoByteBase64URLToken(t *testing.T) {
	svc, _, _ := newService(t)
	token, tokenID := mustPair(t, svc)
	raw, err := base64.RawURLEncoding.DecodeString(token)
	if err != nil {
		t.Fatalf("token %q is not base64url: %v", token, err)
	}
	if len(raw) != 32 {
		t.Errorf("token is %d bytes, want 32", len(raw))
	}
	if tokenID == "" {
		t.Error("token id is empty")
	}
}

func TestPairingCodeWorksOnce(t *testing.T) {
	svc, _, _ := newService(t)
	ctx := context.Background()
	code, _, err := svc.NewPairingCode(ctx)
	if err != nil {
		t.Fatalf("new pairing code: %v", err)
	}
	if _, _, err := svc.Pair(ctx, code, "iPhone"); err != nil {
		t.Fatalf("first pairing: %v", err)
	}
	if _, _, err := svc.Pair(ctx, code, "iPad"); !errors.Is(err, ErrCodeUsed) || !errors.Is(err, ErrInvalidCode) {
		t.Fatalf("second pairing error = %v, want ErrCodeUsed", err)
	}
}

func TestPairingCodeExpiresAfterTenMinutes(t *testing.T) {
	svc, c, _ := newService(t)
	ctx := context.Background()
	code, _, err := svc.NewPairingCode(ctx)
	if err != nil {
		t.Fatalf("new pairing code: %v", err)
	}
	c.advance(10 * time.Minute)
	if _, _, err := svc.Pair(ctx, code, "iPhone"); !errors.Is(err, ErrCodeExpired) || !errors.Is(err, ErrInvalidCode) {
		t.Fatalf("pairing with an expired code error = %v, want ErrCodeExpired", err)
	}
}

func TestPairRejectsUnknownCode(t *testing.T) {
	svc, _, _ := newService(t)
	_, _, err := svc.Pair(context.Background(), "AAAAAAAA", "iPhone")
	if !errors.Is(err, ErrInvalidCode) || errors.Is(err, ErrCodeExpired) || errors.Is(err, ErrCodeUsed) {
		t.Fatalf("error = %v, want only ErrInvalidCode", err)
	}
}

func TestPairAcceptsHandTypedCode(t *testing.T) {
	svc, _, _ := newService(t)
	ctx := context.Background()
	code, _, err := svc.NewPairingCode(ctx)
	if err != nil {
		t.Fatalf("new pairing code: %v", err)
	}
	if _, _, err := svc.Pair(ctx, " "+strings.ToLower(code)+" ", "iPhone"); err != nil {
		t.Fatalf("pairing with a lower-case code: %v", err)
	}
}

func TestAuthenticate(t *testing.T) {
	svc, _, _ := newService(t)
	ctx := context.Background()
	token, tokenID := mustPair(t, svc)

	record, err := svc.Authenticate(ctx, token)
	if err != nil {
		t.Fatalf("authenticate: %v", err)
	}
	if record.ID != tokenID || record.DeviceName != "iPhone" {
		t.Errorf("record = %+v, want id %s for iPhone", record, tokenID)
	}
	if _, err := svc.Authenticate(ctx, token+"x"); !errors.Is(err, ErrInvalidToken) {
		t.Errorf("unknown token error = %v, want ErrInvalidToken", err)
	}
	if _, err := svc.Authenticate(ctx, ""); !errors.Is(err, ErrInvalidToken) {
		t.Errorf("empty token error = %v, want ErrInvalidToken", err)
	}
}

func TestRevokedTokenFailsAuthentication(t *testing.T) {
	svc, _, _ := newService(t)
	ctx := context.Background()
	token, tokenID := mustPair(t, svc)
	other, _ := mustPair(t, svc)

	if err := svc.Revoke(ctx, tokenID); err != nil {
		t.Fatalf("revoke: %v", err)
	}
	if _, err := svc.Authenticate(ctx, token); !errors.Is(err, ErrInvalidToken) {
		t.Errorf("revoked token error = %v, want ErrInvalidToken", err)
	}
	if _, err := svc.Authenticate(ctx, other); err != nil {
		t.Errorf("revoking one device broke another: %v", err)
	}
	if err := svc.Revoke(ctx, "missing"); !errors.Is(err, ErrTokenNotFound) {
		t.Errorf("revoke of unknown id error = %v, want ErrTokenNotFound", err)
	}
}

func TestAuthenticateRecordsLastUse(t *testing.T) {
	svc, c, _ := newService(t)
	ctx := context.Background()
	token, _ := mustPair(t, svc)

	c.advance(time.Hour)
	if _, err := svc.Authenticate(ctx, token); err != nil {
		t.Fatalf("authenticate: %v", err)
	}
	tokens, err := svc.Tokens(ctx)
	if err != nil {
		t.Fatalf("list tokens: %v", err)
	}
	if len(tokens) != 1 || tokens[0].LastUsedAt == nil || !tokens[0].LastUsedAt.Equal(c.now()) {
		t.Errorf("tokens = %+v, want last use at %s", tokens, c.now())
	}
}

// The database must never hold a usable secret: a leaked pulse.db must not
// let anyone authenticate or pair.
func TestDatabaseHoldsNoPlaintextSecrets(t *testing.T) {
	svc, _, dbPath := newService(t)
	ctx := context.Background()
	usedCode, _, err := svc.NewPairingCode(ctx)
	if err != nil {
		t.Fatalf("new pairing code: %v", err)
	}
	token, _, err := svc.Pair(ctx, usedCode, "iPhone")
	if err != nil {
		t.Fatalf("pair: %v", err)
	}
	pendingCode, _, err := svc.NewPairingCode(ctx)
	if err != nil {
		t.Fatalf("new pairing code: %v", err)
	}

	var content []byte
	for _, path := range []string{dbPath, dbPath + "-wal"} {
		data, err := os.ReadFile(path) //nolint:gosec // test-owned temp file
		if err != nil && !errors.Is(err, os.ErrNotExist) {
			t.Fatalf("read %s: %v", path, err)
		}
		content = append(content, data...)
	}
	if len(content) == 0 {
		t.Fatal("database files are empty")
	}
	for name, secret := range map[string]string{"token": token, "used code": usedCode, "pending code": pendingCode} {
		if bytes.Contains(content, []byte(secret)) {
			t.Errorf("database contains the plaintext %s", name)
		}
	}
}
