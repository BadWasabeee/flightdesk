// Package store is the server's SQLite database (pure Go, modernc.org/sqlite): flight legs with
// compact track blobs, the sightings log, persisted lookups, ACARS messages and a small
// key/value table. It runs in WAL mode with incremental auto-vacuum so pruned space is returned
// to the filesystem.
package store

import (
	"context"
	"database/sql"
	"errors"
	"fmt"
	"net/url"
	"os"
	"path/filepath"
	"strings"
	"time"

	_ "modernc.org/sqlite" // registers the "sqlite" driver
)

// FileName is the database file inside the data directory.
const FileName = "flightdesk.db"

// Store wraps a single-writer connection and a small pool of readers.
type Store struct {
	path string
	w    *sql.DB // exactly one connection: SQLite has one writer anyway
	r    *sql.DB // readers (WAL lets them run alongside the writer)
}

const schema = `
CREATE TABLE IF NOT EXISTS legs (
	id         INTEGER PRIMARY KEY,
	hex        TEXT    NOT NULL,
	callsign   TEXT    NOT NULL DEFAULT '',
	reg        TEXT    NOT NULL DEFAULT '',
	type       TEXT    NOT NULL DEFAULT '',
	first_seen INTEGER NOT NULL,           -- Unix seconds; track times are offsets from this
	last_seen  INTEGER NOT NULL,
	origin     TEXT    NOT NULL DEFAULT '',
	dest       TEXT    NOT NULL DEFAULT '',
	min_dist   REAL,                       -- nm from the area centre
	max_alt    INTEGER NOT NULL DEFAULT 0,
	source     INTEGER NOT NULL DEFAULT 0, -- bit 0: area poller, bit 1: watch
	tier       INTEGER NOT NULL DEFAULT 0, -- 0 full detail, 1 downsampled, 2 no track
	points     INTEGER NOT NULL DEFAULT 0
);
CREATE INDEX IF NOT EXISTS legs_hex_last ON legs(hex, last_seen);
CREATE INDEX IF NOT EXISTS legs_tier_last ON legs(tier, last_seen);
CREATE INDEX IF NOT EXISTS legs_last ON legs(last_seen);

CREATE TABLE IF NOT EXISTS tracks (
	leg_id INTEGER PRIMARY KEY,            -- = legs.id
	data   BLOB NOT NULL                   -- trackenc blob, appended in chunks
);

-- Downsampled tracks live in their own table: moving a leg here deletes its row from tracks,
-- and because old legs occupy contiguous rowids, whole pages of tracks become free and
-- incremental_vacuum can return them (rewriting rows in place would leave half-empty pages).
CREATE TABLE IF NOT EXISTS tracks_coarse (
	leg_id INTEGER PRIMARY KEY,            -- = legs.id
	data   BLOB NOT NULL
);

CREATE TABLE IF NOT EXISTS opensky (
	leg_id     INTEGER PRIMARY KEY,        -- = legs.id
	fetched_at INTEGER NOT NULL,
	base       INTEGER NOT NULL,
	data       BLOB    NOT NULL            -- trackenc blob of OpenSky's waypoints
);

CREATE TABLE IF NOT EXISTS sightings (
	hex          TEXT PRIMARY KEY,
	registration TEXT    NOT NULL DEFAULT '',
	type_code    TEXT    NOT NULL DEFAULT '',
	operator     TEXT    NOT NULL DEFAULT '',
	airline_icao TEXT    NOT NULL DEFAULT '',
	first_seen   INTEGER NOT NULL,
	last_seen    INTEGER NOT NULL,
	visits       INTEGER NOT NULL DEFAULT 1,
	callsigns    TEXT    NOT NULL DEFAULT '', -- comma separated, most recent last
	closest_nm   REAL    NOT NULL,
	closest_at   INTEGER NOT NULL,
	max_alt      INTEGER NOT NULL DEFAULT 0,
	routes       TEXT    NOT NULL DEFAULT ''  -- comma separated "ORD-DEN", most recent last
) WITHOUT ROWID;
CREATE INDEX IF NOT EXISTS sightings_last ON sightings(last_seen, hex);

CREATE TABLE IF NOT EXISTS lookups (
	kind       TEXT    NOT NULL,
	key        TEXT    NOT NULL,
	status     INTEGER NOT NULL,
	body       BLOB    NOT NULL,
	fetched_at INTEGER NOT NULL,
	expires_at INTEGER NOT NULL,
	PRIMARY KEY (kind, key)
) WITHOUT ROWID;

CREATE TABLE IF NOT EXISTS acars (
	id        INTEGER PRIMARY KEY,         -- Airframes message id
	hex       TEXT    NOT NULL,
	flight_id INTEGER NOT NULL DEFAULT 0,
	ts        INTEGER NOT NULL,
	label     TEXT    NOT NULL DEFAULT '',
	body      BLOB    NOT NULL             -- the message JSON as Airframes sent it
);
CREATE INDEX IF NOT EXISTS acars_hex_ts ON acars(hex, ts);
CREATE INDEX IF NOT EXISTS acars_ts ON acars(ts);

CREATE TABLE IF NOT EXISTS kv (
	key   TEXT PRIMARY KEY,
	value BLOB NOT NULL
) WITHOUT ROWID;
`

func dsn(path string, readOnly bool) string {
	q := url.Values{}
	// auto_vacuum only takes effect before the first table is created, so it comes first.
	pragmas := []string{"auto_vacuum(INCREMENTAL)", "busy_timeout(10000)", "journal_mode(WAL)",
		"synchronous(NORMAL)", "temp_store(MEMORY)"}
	if readOnly {
		pragmas = append(pragmas, "query_only(1)", "cache_size(-2000)")
	} else {
		pragmas = append(pragmas, "cache_size(-8000)")
		q.Set("_txlock", "immediate")
	}
	for _, p := range pragmas {
		q.Add("_pragma", p)
	}
	return "file:" + filepath.ToSlash(path) + "?" + q.Encode()
}

// Open opens (creating if needed) the database in dir.
func Open(ctx context.Context, dir string) (*Store, error) {
	if err := os.MkdirAll(dir, 0o750); err != nil {
		return nil, fmt.Errorf("data dir: %w", err)
	}
	path := filepath.Join(dir, FileName)
	w, err := sql.Open("sqlite", dsn(path, false))
	if err != nil {
		return nil, err
	}
	w.SetMaxOpenConns(1)
	w.SetConnMaxIdleTime(0)
	if _, err := w.ExecContext(ctx, schema); err != nil {
		w.Close()
		return nil, fmt.Errorf("schema: %w", err)
	}
	r, err := sql.Open("sqlite", dsn(path, true))
	if err != nil {
		w.Close()
		return nil, err
	}
	r.SetMaxOpenConns(4)
	r.SetMaxIdleConns(2)
	return &Store{path: path, w: w, r: r}, nil
}

// Close closes the database after a final checkpoint.
func (s *Store) Close() error {
	_, _ = s.w.Exec("PRAGMA wal_checkpoint(TRUNCATE)")
	return errors.Join(s.r.Close(), s.w.Close())
}

// Path is the database file path.
func (s *Store) Path() string { return s.path }

// AutoVacuum returns the auto_vacuum mode (2 = incremental).
func (s *Store) AutoVacuum(ctx context.Context) (int, error) {
	var v int
	err := s.w.QueryRowContext(ctx, "PRAGMA auto_vacuum").Scan(&v)
	return v, err
}

// JournalMode returns the journal mode ("wal").
func (s *Store) JournalMode(ctx context.Context) (string, error) {
	var v string
	err := s.w.QueryRowContext(ctx, "PRAGMA journal_mode").Scan(&v)
	return strings.ToLower(v), err
}

// Sizes describes the database's disk use.
type Sizes struct {
	FileBytes int64 `json:"fileBytes"` // main database file
	WALBytes  int64 `json:"walBytes"`  // write-ahead log
	UsedBytes int64 `json:"usedBytes"` // pages in use (file minus free pages)
	FreeBytes int64 `json:"freeBytes"` // free pages not yet returned by incremental vacuum
}

// Total is everything on disk.
func (z Sizes) Total() int64 { return z.FileBytes + z.WALBytes }

// Sizes reads the database's disk use.
func (s *Store) Sizes(ctx context.Context) (Sizes, error) {
	var z Sizes
	var pages, free, pageSize int64
	if err := s.w.QueryRowContext(ctx, "PRAGMA page_count").Scan(&pages); err != nil {
		return z, err
	}
	if err := s.w.QueryRowContext(ctx, "PRAGMA freelist_count").Scan(&free); err != nil {
		return z, err
	}
	if err := s.w.QueryRowContext(ctx, "PRAGMA page_size").Scan(&pageSize); err != nil {
		return z, err
	}
	z.UsedBytes = (pages - free) * pageSize
	z.FreeBytes = free * pageSize
	if fi, err := os.Stat(s.path); err == nil {
		z.FileBytes = fi.Size()
	}
	if fi, err := os.Stat(s.path + "-wal"); err == nil {
		z.WALBytes = fi.Size()
	}
	return z, nil
}

// Vacuum returns free pages to the filesystem and truncates the WAL.
func (s *Store) Vacuum(ctx context.Context) error {
	if _, err := s.w.ExecContext(ctx, "PRAGMA incremental_vacuum"); err != nil {
		return err
	}
	_, err := s.w.ExecContext(ctx, "PRAGMA wal_checkpoint(TRUNCATE)")
	return err
}

// Counts are table row counts.
type Counts struct {
	Legs         int64 `json:"legs"`
	LegsDetail   int64 `json:"legsFullDetail"`
	LegsCoarse   int64 `json:"legsDownsampled"`
	Tracks       int64 `json:"tracks"`
	TrackBytes   int64 `json:"trackBytes"`
	TrackPoints  int64 `json:"trackPoints"`
	OpenSky      int64 `json:"openskyTracks"`
	Sightings    int64 `json:"sightings"`
	Acars        int64 `json:"acarsMessages"`
	Lookups      int64 `json:"lookups"`
	OldestLegAge int64 `json:"oldestLegSeconds"`
}

// Counts returns row counts (a few full scans: call it sparingly and cache the result).
func (s *Store) Counts(ctx context.Context, now time.Time) (Counts, error) {
	var c Counts
	var oldest sql.NullInt64
	q := []struct {
		sql  string
		dest []any
	}{
		{"SELECT count(*), coalesce(sum(tier=0),0), coalesce(sum(tier=1),0), coalesce(sum(points),0), min(first_seen) FROM legs",
			[]any{&c.Legs, &c.LegsDetail, &c.LegsCoarse, &c.TrackPoints, &oldest}},
		{"SELECT (SELECT count(*) FROM tracks) + (SELECT count(*) FROM tracks_coarse), " +
			"(SELECT coalesce(sum(length(CAST(data AS BLOB))),0) FROM tracks) + (SELECT coalesce(sum(length(data)),0) FROM tracks_coarse)",
			[]any{&c.Tracks, &c.TrackBytes}},
		{"SELECT count(*) FROM opensky", []any{&c.OpenSky}},
		{"SELECT count(*) FROM sightings", []any{&c.Sightings}},
		{"SELECT count(*) FROM acars", []any{&c.Acars}},
		{"SELECT count(*) FROM lookups", []any{&c.Lookups}},
	}
	for _, x := range q {
		if err := s.r.QueryRowContext(ctx, x.sql).Scan(x.dest...); err != nil {
			return c, err
		}
	}
	if oldest.Valid {
		c.OldestLegAge = now.Unix() - oldest.Int64
	}
	return c, nil
}

// KVGet reads a value (nil, false when absent).
func (s *Store) KVGet(ctx context.Context, key string) ([]byte, bool, error) {
	var v []byte
	err := s.r.QueryRowContext(ctx, "SELECT value FROM kv WHERE key = ?", key).Scan(&v)
	if errors.Is(err, sql.ErrNoRows) {
		return nil, false, nil
	}
	return v, err == nil, err
}

// KVPut writes a value.
func (s *Store) KVPut(ctx context.Context, key string, value []byte) error {
	_, err := s.w.ExecContext(ctx, "INSERT INTO kv(key, value) VALUES(?, ?) ON CONFLICT(key) DO UPDATE SET value = excluded.value", key, value)
	return err
}
