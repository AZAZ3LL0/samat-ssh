-- Timestamps are unix milliseconds, UTC.

CREATE TABLE tokens (
  id           TEXT PRIMARY KEY,
  device_name  TEXT NOT NULL,
  token_sha256 BLOB NOT NULL UNIQUE,
  created_at   INTEGER NOT NULL,
  last_used_at INTEGER,
  revoked_at   INTEGER
);

CREATE TABLE pairing_codes (
  code_sha256 BLOB PRIMARY KEY,
  expires_at  INTEGER NOT NULL,
  used_at     INTEGER
);

CREATE TABLE idempotency (
  key          TEXT PRIMARY KEY,
  request_hash BLOB NOT NULL,
  status_code  INTEGER NOT NULL,
  response     BLOB NOT NULL,
  created_at   INTEGER NOT NULL
);
CREATE INDEX idempotency_created_at ON idempotency(created_at);

-- key examples: "host.cpu.usage_ratio", "project.compose:web.memory_used_bytes"
CREATE TABLE series (
  id  INTEGER PRIMARY KEY,
  key TEXT NOT NULL UNIQUE
);

-- tier: 1 = 1 minute buckets, 2 = 15 minute buckets; ts is the bucket start.
CREATE TABLE samples (
  tier      INTEGER NOT NULL,
  series_id INTEGER NOT NULL REFERENCES series(id),
  ts        INTEGER NOT NULL,
  min       REAL NOT NULL,
  avg       REAL NOT NULL,
  max       REAL NOT NULL,
  PRIMARY KEY (tier, series_id, ts)
) WITHOUT ROWID;
