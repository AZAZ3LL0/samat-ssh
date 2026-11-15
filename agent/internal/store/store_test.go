package store

import (
	"context"
	"errors"
	"path/filepath"
	"testing"
	"testing/fstest"
	"time"
)

func openTemp(t *testing.T) *Store {
	t.Helper()
	st, err := Open(context.Background(), filepath.Join(t.TempDir(), "pulse.db"))
	if err != nil {
		t.Fatalf("open store: %v", err)
	}
	t.Cleanup(func() { _ = st.Close() })
	return st
}

func TestOpenCreatesV1Tables(t *testing.T) {
	st := openTemp(t)
	for _, table := range []string{"schema_migrations", "tokens", "pairing_codes", "idempotency", "series", "samples"} {
		var name string
		err := st.db.QueryRow(`SELECT name FROM sqlite_master WHERE type = 'table' AND name = ?`, table).Scan(&name)
		if err != nil {
			t.Errorf("table %s is missing: %v", table, err)
		}
	}
	var mode string
	if err := st.db.QueryRow(`PRAGMA journal_mode`).Scan(&mode); err != nil {
		t.Fatalf("read journal_mode: %v", err)
	}
	if mode != "wal" {
		t.Errorf("journal_mode = %q, want wal", mode)
	}
}

func TestReopenAppliesEachMigrationOnce(t *testing.T) {
	ctx := context.Background()
	path := filepath.Join(t.TempDir(), "pulse.db")
	for range 2 {
		st, err := Open(ctx, path)
		if err != nil {
			t.Fatalf("open store: %v", err)
		}
		var applied int
		if err := st.db.QueryRow(`SELECT COUNT(*) FROM schema_migrations`).Scan(&applied); err != nil {
			t.Fatalf("count migrations: %v", err)
		}
		if applied != 1 {
			t.Fatalf("applied migrations = %d, want 1", applied)
		}
		if err := st.Close(); err != nil {
			t.Fatalf("close store: %v", err)
		}
	}
}

func TestFailedMigrationRollsBack(t *testing.T) {
	ctx := context.Background()
	path := filepath.Join(t.TempDir(), "pulse.db")
	broken := fstest.MapFS{
		"0001_ok.sql":     {Data: []byte(`CREATE TABLE a (id INTEGER);`)},
		"0002_broken.sql": {Data: []byte(`CREATE TABLE b (id INTEGER); THIS IS NOT SQL;`)},
	}
	if _, err := open(ctx, path, broken); err == nil {
		t.Fatal("open with a broken migration succeeded")
	}

	fixed := fstest.MapFS{
		"0001_ok.sql":    broken["0001_ok.sql"],
		"0002_fixed.sql": {Data: []byte(`CREATE TABLE b (id INTEGER);`)},
	}
	st, err := open(ctx, path, fixed)
	if err != nil {
		t.Fatalf("open after fixing the migration: %v", err)
	}
	defer func() { _ = st.Close() }()
	var version int
	if err := st.db.QueryRow(`SELECT MAX(version) FROM schema_migrations`).Scan(&version); err != nil {
		t.Fatalf("read version: %v", err)
	}
	if version != 2 {
		t.Errorf("schema version = %d, want 2", version)
	}
}

func TestPairDeviceConsumesCodeOnce(t *testing.T) {
	ctx := context.Background()
	st := openTemp(t)
	now := time.UnixMilli(1_700_000_000_000)
	code := []byte("code-hash")
	if err := st.InsertPairingCode(ctx, code, now, now.Add(10*time.Minute)); err != nil {
		t.Fatalf("insert code: %v", err)
	}

	if err := st.PairDevice(ctx, code, "t1", "iPhone", []byte("hash-1"), now); err != nil {
		t.Fatalf("first pairing: %v", err)
	}
	err := st.PairDevice(ctx, code, "t2", "iPad", []byte("hash-2"), now)
	if !errors.Is(err, ErrPairingCodeInvalid) {
		t.Fatalf("second pairing error = %v, want ErrPairingCodeInvalid", err)
	}
	tokens, err := st.ListTokens(ctx)
	if err != nil {
		t.Fatalf("list tokens: %v", err)
	}
	if len(tokens) != 1 || tokens[0].ID != "t1" {
		t.Fatalf("tokens = %+v, want only t1", tokens)
	}
}

func TestPairDeviceRejectsExpiredAndUnknownCode(t *testing.T) {
	ctx := context.Background()
	st := openTemp(t)
	now := time.UnixMilli(1_700_000_000_000)
	code := []byte("code-hash")
	if err := st.InsertPairingCode(ctx, code, now, now.Add(10*time.Minute)); err != nil {
		t.Fatalf("insert code: %v", err)
	}

	atExpiry := now.Add(10 * time.Minute)
	if err := st.PairDevice(ctx, code, "t1", "iPhone", []byte("hash-1"), atExpiry); !errors.Is(err, ErrPairingCodeInvalid) {
		t.Errorf("expired code error = %v, want ErrPairingCodeInvalid", err)
	}
	if err := st.PairDevice(ctx, []byte("other"), "t1", "iPhone", []byte("hash-1"), now); !errors.Is(err, ErrPairingCodeInvalid) {
		t.Errorf("unknown code error = %v, want ErrPairingCodeInvalid", err)
	}
}

func TestRevokeToken(t *testing.T) {
	ctx := context.Background()
	st := openTemp(t)
	now := time.UnixMilli(1_700_000_000_000)
	code := []byte("code-hash")
	if err := st.InsertPairingCode(ctx, code, now, now.Add(time.Minute)); err != nil {
		t.Fatalf("insert code: %v", err)
	}
	if err := st.PairDevice(ctx, code, "t1", "iPhone", []byte("hash-1"), now); err != nil {
		t.Fatalf("pair: %v", err)
	}

	if err := st.RevokeToken(ctx, "t1", now.Add(time.Second)); err != nil {
		t.Fatalf("revoke: %v", err)
	}
	token, err := st.TokenByHash(ctx, []byte("hash-1"))
	if err != nil {
		t.Fatalf("token by hash: %v", err)
	}
	if token.RevokedAt == nil {
		t.Error("revoked token has no revoked_at")
	}
	if err := st.RevokeToken(ctx, "t1", now); !errors.Is(err, ErrNotFound) {
		t.Errorf("second revoke error = %v, want ErrNotFound", err)
	}
	if err := st.RevokeToken(ctx, "missing", now); !errors.Is(err, ErrNotFound) {
		t.Errorf("revoke of unknown id error = %v, want ErrNotFound", err)
	}
}
