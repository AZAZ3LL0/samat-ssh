package store

import (
	"context"
	"database/sql"
	"errors"
	"fmt"
	"time"
)

// IdempotencyRecord is the stored outcome of a mutating request.
type IdempotencyRecord struct {
	Key         string
	RequestHash []byte
	StatusCode  int
	Response    []byte
	CreatedAt   time.Time
}

// GetIdempotency returns the record for key, or ErrNotFound.
func (s *Store) GetIdempotency(ctx context.Context, key string) (IdempotencyRecord, error) {
	record := IdempotencyRecord{Key: key}
	var createdAt int64
	err := s.db.QueryRowContext(ctx,
		`SELECT request_hash, status_code, response, created_at FROM idempotency WHERE key = ?`, key,
	).Scan(&record.RequestHash, &record.StatusCode, &record.Response, &createdAt)
	if errors.Is(err, sql.ErrNoRows) {
		return IdempotencyRecord{}, ErrNotFound
	}
	if err != nil {
		return IdempotencyRecord{}, fmt.Errorf("select idempotency record: %w", err)
	}
	record.CreatedAt = time.UnixMilli(createdAt).UTC()
	return record, nil
}

// PutIdempotency stores a record, replacing an expired one with the same key.
func (s *Store) PutIdempotency(ctx context.Context, record IdempotencyRecord) error {
	if _, err := s.db.ExecContext(ctx,
		`INSERT OR REPLACE INTO idempotency (key, request_hash, status_code, response, created_at) VALUES (?, ?, ?, ?, ?)`,
		record.Key, record.RequestHash, record.StatusCode, record.Response, toMillis(record.CreatedAt),
	); err != nil {
		return fmt.Errorf("insert idempotency record: %w", err)
	}
	return nil
}

// PurgeIdempotency deletes records created before the cutoff.
func (s *Store) PurgeIdempotency(ctx context.Context, before time.Time) error {
	if _, err := s.db.ExecContext(ctx, `DELETE FROM idempotency WHERE created_at < ?`, toMillis(before)); err != nil {
		return fmt.Errorf("purge idempotency records: %w", err)
	}
	return nil
}
