// Package store owns the agent's SQLite database and its migrations.
package store

import (
	"context"
	"database/sql"
	"embed"
	"errors"
	"fmt"
	"io/fs"
	"sort"
	"strconv"
	"strings"
	"time"

	_ "modernc.org/sqlite" // registers the "sqlite" driver; pure Go, the agent builds without CGO
)

//go:embed migrations/*.sql
var embedded embed.FS

const (
	openRetryFor   = 5 * time.Second
	openRetryEvery = 20 * time.Millisecond
)

// ErrNotFound reports a missing row.
var ErrNotFound = errors.New("store: not found")

// Store is the agent database handle.
type Store struct {
	db *sql.DB
}

// Open opens the database at path and applies pending migrations.
func Open(ctx context.Context, path string) (*Store, error) {
	migrations, err := fs.Sub(embedded, "migrations")
	if err != nil {
		return nil, fmt.Errorf("locate migrations: %w", err)
	}
	return open(ctx, path, migrations)
}

func open(ctx context.Context, path string, migrations fs.FS) (*Store, error) {
	// busy_timeout comes first so the switch to WAL waits for a concurrent CLI
	// instead of failing. Immediate transactions take the write lock up front,
	// which keeps read-then-write sequences from racing between the agent and the CLI.
	dsn := "file:" + path +
		"?_pragma=busy_timeout(5000)&_pragma=journal_mode(WAL)&_pragma=foreign_keys(1)&_txlock=immediate"
	db, err := sql.Open("sqlite", dsn)
	if err != nil {
		return nil, fmt.Errorf("open database %s: %w", path, err)
	}
	if err := migrateWithRetry(ctx, db, migrations); err != nil {
		_ = db.Close()
		return nil, fmt.Errorf("migrate database %s: %w", path, err)
	}
	return &Store{db: db}, nil
}

// migrateWithRetry rides out a concurrent first open. While another process
// creates the file and switches it to WAL, SQLite reports SQLITE_BUSY at once
// instead of waiting for busy_timeout, and the agent and `pulse-agent pair`
// do start together on a fresh install.
func migrateWithRetry(ctx context.Context, db *sql.DB, migrations fs.FS) error {
	deadline := time.Now().Add(openRetryFor)
	for {
		err := migrate(ctx, db, migrations)
		if err == nil || !isBusy(err) || time.Now().After(deadline) {
			return err
		}
		select {
		case <-ctx.Done():
			return ctx.Err()
		case <-time.After(openRetryEvery):
		}
	}
}

func isBusy(err error) bool {
	var coded interface{ Code() int }
	// The low byte is the primary result code; SQLITE_BUSY is 5.
	return errors.As(err, &coded) && coded.Code()&0xff == 5
}

// Close releases the database.
func (s *Store) Close() error {
	return s.db.Close()
}

type migration struct {
	version int
	name    string
}

func listMigrations(migrations fs.FS) ([]migration, error) {
	entries, err := fs.ReadDir(migrations, ".")
	if err != nil {
		return nil, fmt.Errorf("read migrations: %w", err)
	}
	var list []migration
	for _, entry := range entries {
		name := entry.Name()
		if entry.IsDir() || !strings.HasSuffix(name, ".sql") {
			continue
		}
		prefix, _, ok := strings.Cut(name, "_")
		if !ok {
			return nil, fmt.Errorf("migration %s: want NNNN_<name>.sql", name)
		}
		version, err := strconv.Atoi(prefix)
		if err != nil || version < 1 {
			return nil, fmt.Errorf("migration %s: want NNNN_<name>.sql", name)
		}
		list = append(list, migration{version: version, name: name})
	}
	sort.Slice(list, func(i, j int) bool { return list[i].version < list[j].version })
	for i := 1; i < len(list); i++ {
		if list[i].version == list[i-1].version {
			return nil, fmt.Errorf("migrations %s and %s share a version", list[i-1].name, list[i].name)
		}
	}
	return list, nil
}

func migrate(ctx context.Context, db *sql.DB, migrations fs.FS) error {
	list, err := listMigrations(migrations)
	if err != nil {
		return err
	}
	tx, err := db.BeginTx(ctx, nil)
	if err != nil {
		return fmt.Errorf("begin: %w", err)
	}
	defer func() { _ = tx.Rollback() }()

	if _, err := tx.ExecContext(ctx,
		`CREATE TABLE IF NOT EXISTS schema_migrations (version INTEGER PRIMARY KEY, applied_at INTEGER NOT NULL)`,
	); err != nil {
		return fmt.Errorf("create schema_migrations: %w", err)
	}
	var current int
	if err := tx.QueryRowContext(ctx, `SELECT COALESCE(MAX(version), 0) FROM schema_migrations`).Scan(&current); err != nil {
		return fmt.Errorf("read schema version: %w", err)
	}
	for _, m := range list {
		if m.version <= current {
			continue
		}
		script, err := fs.ReadFile(migrations, m.name)
		if err != nil {
			return fmt.Errorf("read migration %s: %w", m.name, err)
		}
		if _, err := tx.ExecContext(ctx, string(script)); err != nil {
			return fmt.Errorf("apply migration %s: %w", m.name, err)
		}
		if _, err := tx.ExecContext(ctx,
			`INSERT INTO schema_migrations (version, applied_at) VALUES (?, ?)`, m.version, toMillis(time.Now()),
		); err != nil {
			return fmt.Errorf("record migration %s: %w", m.name, err)
		}
	}
	if err := tx.Commit(); err != nil {
		return fmt.Errorf("commit: %w", err)
	}
	return nil
}

func toMillis(t time.Time) int64 {
	return t.UnixMilli()
}

func fromMillis(ms sql.NullInt64) *time.Time {
	if !ms.Valid {
		return nil
	}
	t := time.UnixMilli(ms.Int64).UTC()
	return &t
}
