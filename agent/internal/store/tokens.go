package store

import (
	"context"
	"database/sql"
	"errors"
	"fmt"
	"time"
)

var (
	// ErrPairingCodeInvalid reports a pairing code that cannot pair: unknown,
	// expired or already used. The two errors below wrap it.
	ErrPairingCodeInvalid = errors.New("store: pairing code invalid")
	// ErrPairingCodeExpired reports a known, unused code past its expiry.
	ErrPairingCodeExpired = fmt.Errorf("%w: expired", ErrPairingCodeInvalid)
	// ErrPairingCodeUsed reports a code that already paired a device.
	ErrPairingCodeUsed = fmt.Errorf("%w: already used", ErrPairingCodeInvalid)
)

// Token is a device token record. The token itself is never stored, only its hash.
type Token struct {
	ID         string
	DeviceName string
	CreatedAt  time.Time
	LastUsedAt *time.Time
	RevokedAt  *time.Time
}

// InsertPairingCode stores the hash of a fresh pairing code and drops expired ones.
func (s *Store) InsertPairingCode(ctx context.Context, codeHash []byte, now, expiresAt time.Time) error {
	tx, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return fmt.Errorf("begin: %w", err)
	}
	defer func() { _ = tx.Rollback() }()

	if _, err := tx.ExecContext(ctx, `DELETE FROM pairing_codes WHERE expires_at <= ?`, toMillis(now)); err != nil {
		return fmt.Errorf("purge pairing codes: %w", err)
	}
	if _, err := tx.ExecContext(ctx,
		`INSERT INTO pairing_codes (code_sha256, expires_at) VALUES (?, ?)`, codeHash, toMillis(expiresAt),
	); err != nil {
		return fmt.Errorf("insert pairing code: %w", err)
	}
	if err := tx.Commit(); err != nil {
		return fmt.Errorf("commit: %w", err)
	}
	return nil
}

// PairDevice consumes a pairing code and creates the device token in one
// transaction, so a code can never yield two tokens.
func (s *Store) PairDevice(ctx context.Context, codeHash []byte, tokenID, deviceName string, tokenHash []byte, now time.Time) error {
	tx, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return fmt.Errorf("begin: %w", err)
	}
	defer func() { _ = tx.Rollback() }()

	res, err := tx.ExecContext(ctx,
		`UPDATE pairing_codes SET used_at = ? WHERE code_sha256 = ? AND used_at IS NULL AND expires_at > ?`,
		toMillis(now), codeHash, toMillis(now),
	)
	if err != nil {
		return fmt.Errorf("consume pairing code: %w", err)
	}
	consumed, err := res.RowsAffected()
	if err != nil {
		return fmt.Errorf("consume pairing code: %w", err)
	}
	if consumed == 0 {
		return whyUnusable(ctx, tx, codeHash)
	}
	if _, err := tx.ExecContext(ctx,
		`INSERT INTO tokens (id, device_name, token_sha256, created_at) VALUES (?, ?, ?, ?)`,
		tokenID, deviceName, tokenHash, toMillis(now),
	); err != nil {
		return fmt.Errorf("insert token: %w", err)
	}
	if err := tx.Commit(); err != nil {
		return fmt.Errorf("commit: %w", err)
	}
	return nil
}

// whyUnusable tells an unknown code from an expired or used one. Expired codes
// are purged when the next code is made, after which they read as unknown.
func whyUnusable(ctx context.Context, tx *sql.Tx, codeHash []byte) error {
	var usedAt sql.NullInt64
	err := tx.QueryRowContext(ctx, `SELECT used_at FROM pairing_codes WHERE code_sha256 = ?`, codeHash).Scan(&usedAt)
	switch {
	case errors.Is(err, sql.ErrNoRows):
		return ErrPairingCodeInvalid
	case err != nil:
		return fmt.Errorf("read pairing code: %w", err)
	case usedAt.Valid:
		return ErrPairingCodeUsed
	default:
		return ErrPairingCodeExpired
	}
}

// TokenByHash returns the token with the given hash, revoked or not.
func (s *Store) TokenByHash(ctx context.Context, tokenHash []byte) (Token, error) {
	row := s.db.QueryRowContext(ctx,
		`SELECT id, device_name, created_at, last_used_at, revoked_at FROM tokens WHERE token_sha256 = ?`, tokenHash)
	token, err := scanToken(row)
	if errors.Is(err, sql.ErrNoRows) {
		return Token{}, ErrNotFound
	}
	if err != nil {
		return Token{}, fmt.Errorf("select token: %w", err)
	}
	return token, nil
}

// ListTokens returns every token, oldest first.
func (s *Store) ListTokens(ctx context.Context) ([]Token, error) {
	rows, err := s.db.QueryContext(ctx,
		`SELECT id, device_name, created_at, last_used_at, revoked_at FROM tokens ORDER BY created_at, id`)
	if err != nil {
		return nil, fmt.Errorf("select tokens: %w", err)
	}
	defer func() { _ = rows.Close() }()

	var tokens []Token
	for rows.Next() {
		token, err := scanToken(rows)
		if err != nil {
			return nil, fmt.Errorf("scan token: %w", err)
		}
		tokens = append(tokens, token)
	}
	if err := rows.Err(); err != nil {
		return nil, fmt.Errorf("select tokens: %w", err)
	}
	return tokens, nil
}

// TouchToken records the last use of a token.
func (s *Store) TouchToken(ctx context.Context, id string, now time.Time) error {
	if _, err := s.db.ExecContext(ctx, `UPDATE tokens SET last_used_at = ? WHERE id = ?`, toMillis(now), id); err != nil {
		return fmt.Errorf("touch token %s: %w", id, err)
	}
	return nil
}

// RevokeToken revokes an active token. It returns ErrNotFound when the id is
// unknown or the token is already revoked.
func (s *Store) RevokeToken(ctx context.Context, id string, now time.Time) error {
	res, err := s.db.ExecContext(ctx,
		`UPDATE tokens SET revoked_at = ? WHERE id = ? AND revoked_at IS NULL`, toMillis(now), id)
	if err != nil {
		return fmt.Errorf("revoke token %s: %w", id, err)
	}
	revoked, err := res.RowsAffected()
	if err != nil {
		return fmt.Errorf("revoke token %s: %w", id, err)
	}
	if revoked == 0 {
		return ErrNotFound
	}
	return nil
}

type scanner interface {
	Scan(dest ...any) error
}

func scanToken(row scanner) (Token, error) {
	var (
		token              Token
		createdAt          int64
		lastUsed, revokedA sql.NullInt64
	)
	if err := row.Scan(&token.ID, &token.DeviceName, &createdAt, &lastUsed, &revokedA); err != nil {
		return Token{}, err
	}
	token.CreatedAt = time.UnixMilli(createdAt).UTC()
	token.LastUsedAt = fromMillis(lastUsed)
	token.RevokedAt = fromMillis(revokedA)
	return token, nil
}
