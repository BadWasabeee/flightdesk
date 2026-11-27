package store

import (
	"context"
	"database/sql"
	"errors"
	"fmt"
	"strings"

	"github.com/BadWasabeee/flightdesk/Server/internal/trackenc"
)

// Leg sources (bit flags).
const (
	SourceArea  = 1
	SourceWatch = 2
)

// Track tiers.
const (
	TierFull   = 0
	TierCoarse = 1
	TierNone   = 2
)

// Leg is one flight leg's metadata.
type Leg struct {
	ID        int64   `json:"id"`
	Hex       string  `json:"hex"`
	Callsign  string  `json:"callsign"`
	Reg       string  `json:"reg"`
	Type      string  `json:"typeCode"`
	FirstSeen int64   `json:"firstSeen"`
	LastSeen  int64   `json:"lastSeen"`
	Origin    string  `json:"origin,omitempty"`
	Dest      string  `json:"dest,omitempty"`
	MinDist   float64 `json:"minDistanceNM"` // -1 when unknown
	MaxAlt    int     `json:"maxAltitude"`
	Source    int     `json:"source"`
	Tier      int     `json:"tier"`
	Points    int     `json:"points"`
}

// LegWrite is one leg's pending change: its metadata and track bytes to append.
type LegWrite struct {
	Leg       *Leg   // ID 0 = insert (the new ID is written back)
	Append    []byte // trackenc bytes continuing the stored blob
	AddPoints int
}

const legCols = "id, hex, callsign, reg, type, first_seen, last_seen, origin, dest, coalesce(min_dist, -1), max_alt, source, tier, points"

func scanLeg(sc interface{ Scan(...any) error }) (*Leg, error) {
	var l Leg
	err := sc.Scan(&l.ID, &l.Hex, &l.Callsign, &l.Reg, &l.Type, &l.FirstSeen, &l.LastSeen,
		&l.Origin, &l.Dest, &l.MinDist, &l.MaxAlt, &l.Source, &l.Tier, &l.Points)
	return &l, err
}

func nullDist(d float64) any {
	if d < 0 {
		return nil
	}
	return d
}

// WriteBatch applies leg writes and sighting upserts in one transaction. On success each
// Leg's ID (for inserts) and Points are updated in place; on failure they are left unchanged.
func (s *Store) WriteBatch(ctx context.Context, legs []LegWrite, sightings []*Sighting) (err error) {
	if len(legs) == 0 && len(sightings) == 0 {
		return nil
	}
	saved := make([][2]int64, len(legs))
	for i, w := range legs {
		saved[i] = [2]int64{w.Leg.ID, int64(w.Leg.Points)}
	}
	defer func() {
		if err != nil {
			for i, w := range legs {
				w.Leg.ID, w.Leg.Points = saved[i][0], int(saved[i][1])
			}
		}
	}()
	tx, err := s.w.BeginTx(ctx, nil)
	if err != nil {
		return err
	}
	defer tx.Rollback()
	for _, w := range legs {
		l := w.Leg
		if l.ID == 0 {
			res, err := tx.ExecContext(ctx, `INSERT INTO legs(hex, callsign, reg, type, first_seen, last_seen, origin, dest, min_dist, max_alt, source, tier, points)
				VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?)`, l.Hex, l.Callsign, l.Reg, l.Type, l.FirstSeen, l.LastSeen,
				l.Origin, l.Dest, nullDist(l.MinDist), l.MaxAlt, l.Source, l.Tier, l.Points+w.AddPoints)
			if err != nil {
				return fmt.Errorf("insert leg: %w", err)
			}
			if l.ID, err = res.LastInsertId(); err != nil {
				return err
			}
		} else {
			_, err := tx.ExecContext(ctx, `UPDATE legs SET callsign=?, reg=?, type=?, last_seen=?, origin=?, dest=?, min_dist=?, max_alt=?, source=?, points=points+? WHERE id=?`,
				l.Callsign, l.Reg, l.Type, l.LastSeen, l.Origin, l.Dest, nullDist(l.MinDist), l.MaxAlt, l.Source, w.AddPoints, l.ID)
			if err != nil {
				return fmt.Errorf("update leg: %w", err)
			}
		}
		if len(w.Append) > 0 {
			if _, err := tx.ExecContext(ctx, `INSERT INTO tracks(leg_id, data) VALUES(?, ?)
				ON CONFLICT(leg_id) DO UPDATE SET data = CAST(data || excluded.data AS BLOB)`, l.ID, w.Append); err != nil {
				return fmt.Errorf("append track: %w", err)
			}
		}
		l.Points += w.AddPoints
	}
	for _, sg := range sightings {
		if err := upsertSighting(ctx, tx, sg); err != nil {
			return err
		}
	}
	return tx.Commit()
}

// Leg returns a leg by id.
func (s *Store) Leg(ctx context.Context, id int64) (*Leg, error) {
	l, err := scanLeg(s.r.QueryRowContext(ctx, "SELECT "+legCols+" FROM legs WHERE id = ?", id))
	if errors.Is(err, sql.ErrNoRows) {
		return nil, nil
	}
	return l, err
}

// LatestLeg returns the most recent leg for hex last seen at or after since (nil if none).
func (s *Store) LatestLeg(ctx context.Context, hex string, since int64) (*Leg, error) {
	l, err := scanLeg(s.r.QueryRowContext(ctx, "SELECT "+legCols+" FROM legs WHERE hex = ? AND last_seen >= ? ORDER BY last_seen DESC LIMIT 1", hex, since))
	if errors.Is(err, sql.ErrNoRows) {
		return nil, nil
	}
	return l, err
}

// LegsSeenSince returns legs last seen at or after since (used to resume legs after a restart).
func (s *Store) LegsSeenSince(ctx context.Context, since int64) ([]*Leg, error) {
	return s.queryLegs(ctx, "SELECT "+legCols+" FROM legs WHERE last_seen >= ? ORDER BY last_seen", since)
}

// LegsQuery filters leg listings.
type LegsQuery struct {
	Hex      string
	Callsign string
	Since    int64 // last_seen >= Since
	Before   int64 // last_seen < Before (0 = no bound)
	Limit    int
}

// Legs lists legs, newest first.
func (s *Store) Legs(ctx context.Context, q LegsQuery) ([]*Leg, error) {
	var where []string
	var args []any
	where = append(where, "last_seen >= ?")
	args = append(args, q.Since)
	if q.Before > 0 {
		where = append(where, "last_seen < ?")
		args = append(args, q.Before)
	}
	if q.Hex != "" {
		where = append(where, "hex = ?")
		args = append(args, q.Hex)
	}
	if q.Callsign != "" {
		where = append(where, "callsign = ?")
		args = append(args, q.Callsign)
	}
	limit := q.Limit
	if limit <= 0 || limit > 1000 {
		limit = 1000
	}
	args = append(args, limit)
	return s.queryLegs(ctx, "SELECT "+legCols+" FROM legs WHERE "+strings.Join(where, " AND ")+" ORDER BY last_seen DESC LIMIT ?", args...)
}

func (s *Store) queryLegs(ctx context.Context, query string, args ...any) ([]*Leg, error) {
	rows, err := s.r.QueryContext(ctx, query, args...)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []*Leg
	for rows.Next() {
		l, err := scanLeg(rows)
		if err != nil {
			return nil, err
		}
		out = append(out, l)
	}
	return out, rows.Err()
}

// TrackBlob returns a leg's stored track blob, full detail or downsampled (nil if none).
func (s *Store) TrackBlob(ctx context.Context, legID int64) ([]byte, error) {
	var b []byte
	err := s.r.QueryRowContext(ctx, `SELECT data FROM tracks WHERE leg_id = ?1
		UNION ALL SELECT data FROM tracks_coarse WHERE leg_id = ?1 LIMIT 1`, legID).Scan(&b)
	if errors.Is(err, sql.ErrNoRows) {
		return nil, nil
	}
	return b, err
}

// TrackBlobWriter reads a track blob through the writer connection, so it sees every committed
// append (used while holding the tracker lock to avoid racing a flush).
func (s *Store) TrackBlobWriter(ctx context.Context, legID int64) ([]byte, error) {
	var b []byte
	err := s.w.QueryRowContext(ctx, "SELECT data FROM tracks WHERE leg_id = ?", legID).Scan(&b)
	if errors.Is(err, sql.ErrNoRows) {
		return nil, nil
	}
	return b, err
}

// Track returns a leg's decoded points.
func (s *Store) Track(ctx context.Context, l *Leg) ([]trackenc.Point, error) {
	b, err := s.TrackBlob(ctx, l.ID)
	if err != nil || b == nil {
		return nil, err
	}
	return trackenc.Decode(l.FirstSeen, b)
}

// SetRoute fills origin/destination for legs flying callsign that don't have one yet and were
// seen since `since`.
func (s *Store) SetRoute(ctx context.Context, callsign, origin, dest string, since int64) error {
	_, err := s.w.ExecContext(ctx, "UPDATE legs SET origin = ?, dest = ? WHERE callsign = ? AND origin = '' AND last_seen >= ?",
		origin, dest, callsign, since)
	return err
}

// OpenSkyTrack is an OpenSky track stored for a leg.
type OpenSkyTrack struct {
	FetchedAt int64
	Base      int64
	Points    []trackenc.Point
}

// OpenSky returns the stored OpenSky track for a leg.
func (s *Store) OpenSky(ctx context.Context, legID int64) (*OpenSkyTrack, error) {
	var t OpenSkyTrack
	var blob []byte
	err := s.r.QueryRowContext(ctx, "SELECT fetched_at, base, data FROM opensky WHERE leg_id = ?", legID).Scan(&t.FetchedAt, &t.Base, &blob)
	if errors.Is(err, sql.ErrNoRows) {
		return nil, nil
	}
	if err != nil {
		return nil, err
	}
	if t.Points, err = trackenc.Decode(t.Base, blob); err != nil {
		return nil, err
	}
	return &t, nil
}

// PutOpenSky stores an OpenSky track for a leg, encoded compactly.
func (s *Store) PutOpenSky(ctx context.Context, legID, fetchedAt int64, pts []trackenc.Point) error {
	var base int64
	if len(pts) > 0 {
		base = pts[0].T
	}
	blob, err := trackenc.Encode(base, pts)
	if err != nil {
		return err
	}
	_, err = s.w.ExecContext(ctx, `INSERT INTO opensky(leg_id, fetched_at, base, data) VALUES(?,?,?,?)
		ON CONFLICT(leg_id) DO UPDATE SET fetched_at=excluded.fetched_at, base=excluded.base, data=excluded.data`,
		legID, fetchedAt, base, blob)
	return err
}
