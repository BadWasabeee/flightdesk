package store

import (
	"context"
	"fmt"
	"time"

	"github.com/BadWasabeee/flightdesk/Server/internal/trackenc"
)

// Retention is the tiered retention policy.
type Retention struct {
	DetailDays  int   // full-detail tracks kept this long (default 90)
	CoarseDays  int   // downsampled tracks kept this long (default 730); leg rows forever
	AcarsDays   int   // ACARS messages (default 180)
	CoarseEvery int64 // downsampled spacing in seconds (default 300)
}

// DefaultRetention matches the documented defaults.
var DefaultRetention = Retention{DetailDays: 90, CoarseDays: 730, AcarsDays: 180, CoarseEvery: 300}

// Report says what a maintenance pass did.
type Report struct {
	Downsampled     int   `json:"downsampled"`
	TracksDropped   int   `json:"tracksDropped"`
	OpenSkyDropped  int   `json:"openskyDropped"`
	AcarsDeleted    int64 `json:"acarsDeleted"`
	LookupsDeleted  int64 `json:"lookupsDeleted"`
	BytesBefore     int64 `json:"bytesBefore"`
	BytesAfter      int64 `json:"bytesAfter"`
	CapExceeded     bool  `json:"capExceeded,omitempty"`
	CapUnreachable  bool  `json:"capUnreachable,omitempty"`
	OldestTouchedAt int64 `json:"oldestTouchedAt,omitempty"`
	NewestTouchedAt int64 `json:"newestTouchedAt,omitempty"`
}

func (r *Report) touched(t int64) {
	if r.OldestTouchedAt == 0 || t < r.OldestTouchedAt {
		r.OldestTouchedAt = t
	}
	if t > r.NewestTouchedAt {
		r.NewestTouchedAt = t
	}
}

// Any reports whether anything was removed.
func (r Report) Any() bool {
	return r.Downsampled+r.TracksDropped+r.OpenSkyDropped > 0 || r.AcarsDeleted+r.LookupsDeleted > 0
}

const batchSize = 500

// downsampleBatch downsamples up to n of the oldest full-detail legs last seen before `before`.
// It returns how many legs it changed.
func (s *Store) downsampleBatch(ctx context.Context, before int64, n int, every int64, rep *Report) (int, error) {
	tx, err := s.w.BeginTx(ctx, nil)
	if err != nil {
		return 0, err
	}
	defer tx.Rollback()
	rows, err := tx.QueryContext(ctx, `SELECT l.id, l.first_seen, l.last_seen, t.data FROM legs l LEFT JOIN tracks t ON t.leg_id = l.id
		WHERE l.tier = 0 AND l.last_seen < ? ORDER BY l.last_seen LIMIT ?`, before, n)
	if err != nil {
		return 0, err
	}
	type item struct {
		id, base, last int64
		blob           []byte
	}
	var items []item
	for rows.Next() {
		var it item
		if err := rows.Scan(&it.id, &it.base, &it.last, &it.blob); err != nil {
			rows.Close()
			return 0, err
		}
		items = append(items, it)
	}
	rows.Close()
	if err := rows.Err(); err != nil {
		return 0, err
	}
	for _, it := range items {
		points := 0
		if len(it.blob) > 0 {
			pts, err := trackenc.Decode(it.base, it.blob)
			if err != nil {
				// A corrupt blob can't be downsampled; drop it rather than retry forever.
				pts = nil
			}
			pts = trackenc.Downsample(pts, every)
			if len(pts) > 0 {
				blob, err := trackenc.Encode(it.base, pts)
				if err != nil {
					return 0, err
				}
				if _, err := tx.ExecContext(ctx, "INSERT OR REPLACE INTO tracks_coarse(leg_id, data) VALUES(?, ?)", it.id, blob); err != nil {
					return 0, err
				}
				points = len(pts)
			}
			if _, err := tx.ExecContext(ctx, "DELETE FROM tracks WHERE leg_id = ?", it.id); err != nil {
				return 0, err
			}
		}
		if _, err := tx.ExecContext(ctx, "UPDATE legs SET tier = 1, points = ? WHERE id = ?", points, it.id); err != nil {
			return 0, err
		}
		res, err := tx.ExecContext(ctx, "DELETE FROM opensky WHERE leg_id = ?", it.id)
		if err != nil {
			return 0, err
		}
		if k, _ := res.RowsAffected(); k > 0 {
			rep.OpenSkyDropped++
		}
		rep.touched(it.last)
	}
	rep.Downsampled += len(items)
	return len(items), tx.Commit()
}

// dropTracksBatch removes the tracks of up to n of the oldest legs in tier `tier` last seen
// before `before`, keeping the leg rows.
func (s *Store) dropTracksBatch(ctx context.Context, tier int, before int64, n int, rep *Report) (int, error) {
	tx, err := s.w.BeginTx(ctx, nil)
	if err != nil {
		return 0, err
	}
	defer tx.Rollback()
	rows, err := tx.QueryContext(ctx, "SELECT id, last_seen FROM legs WHERE tier = ? AND last_seen < ? ORDER BY last_seen LIMIT ?", tier, before, n)
	if err != nil {
		return 0, err
	}
	var ids, lasts []int64
	for rows.Next() {
		var id, last int64
		if err := rows.Scan(&id, &last); err != nil {
			rows.Close()
			return 0, err
		}
		ids, lasts = append(ids, id), append(lasts, last)
	}
	rows.Close()
	for i, id := range ids {
		for _, q := range []string{"DELETE FROM tracks WHERE leg_id = ?", "DELETE FROM tracks_coarse WHERE leg_id = ?", "DELETE FROM opensky WHERE leg_id = ?",
			"UPDATE legs SET tier = 2, points = 0 WHERE id = ?"} {
			if _, err := tx.ExecContext(ctx, q, id); err != nil {
				return 0, err
			}
		}
		rep.touched(lasts[i])
	}
	rep.TracksDropped += len(ids)
	return len(ids), tx.Commit()
}

func (s *Store) deleteAcarsBefore(ctx context.Context, before int64, limit int) (int64, error) {
	res, err := s.w.ExecContext(ctx, "DELETE FROM acars WHERE id IN (SELECT id FROM acars WHERE ts < ? ORDER BY ts LIMIT ?)", before, limit)
	if err != nil {
		return 0, err
	}
	return res.RowsAffected()
}

// ApplyRetention runs the age-based tiers: downsample full-detail tracks older than DetailDays,
// drop tracks older than CoarseDays (leg rows and sightings stay), delete ACARS older than
// AcarsDays and expired lookups, then return the space to the filesystem.
func (s *Store) ApplyRetention(ctx context.Context, now time.Time, r Retention) (Report, error) {
	var rep Report
	before, _ := s.Sizes(ctx)
	rep.BytesBefore = before.Total()
	day := int64(86400)
	if r.CoarseEvery <= 0 {
		r.CoarseEvery = DefaultRetention.CoarseEvery
	}
	if r.DetailDays > 0 {
		for {
			n, err := s.downsampleBatch(ctx, now.Unix()-int64(r.DetailDays)*day, batchSize, r.CoarseEvery, &rep)
			if err != nil {
				return rep, fmt.Errorf("downsample: %w", err)
			}
			if n < batchSize {
				break
			}
		}
	}
	if r.CoarseDays > 0 {
		for {
			n, err := s.dropTracksBatch(ctx, TierCoarse, now.Unix()-int64(r.CoarseDays)*day, batchSize, &rep)
			if err != nil {
				return rep, fmt.Errorf("drop coarse: %w", err)
			}
			if n < batchSize {
				break
			}
		}
	}
	if r.AcarsDays > 0 {
		for {
			n, err := s.deleteAcarsBefore(ctx, now.Unix()-int64(r.AcarsDays)*day, 5000)
			if err != nil {
				return rep, fmt.Errorf("acars: %w", err)
			}
			rep.AcarsDeleted += n
			if n < 5000 {
				break
			}
		}
	}
	res, err := s.w.ExecContext(ctx, "DELETE FROM lookups WHERE expires_at < ?", now.Unix()-day)
	if err != nil {
		return rep, err
	}
	rep.LookupsDeleted, _ = res.RowsAffected()
	if err := s.Vacuum(ctx); err != nil {
		return rep, err
	}
	after, _ := s.Sizes(ctx)
	rep.BytesAfter = after.Total()
	return rep, nil
}

// EnforceCap prunes until the database is under capBytes, oldest and most detailed first:
//  1. downsample the oldest full-detail tracks (keeping the newest floorDays untouched);
//  2. drop the oldest downsampled tracks;
//  3. delete the oldest ACARS messages;
//  4. downsample even the newest floorDays of full-detail tracks.
//
// Leg metadata and sightings are never pruned (they are tiny). If the cap still can't be met,
// the report says so.
func (s *Store) EnforceCap(ctx context.Context, now time.Time, capBytes int64, floorDays int, every int64) (Report, error) {
	var rep Report
	sz, err := s.Sizes(ctx)
	if err != nil {
		return rep, err
	}
	rep.BytesBefore = sz.Total()
	if capBytes <= 0 || sz.UsedBytes+sz.WALBytes <= capBytes {
		rep.BytesAfter = rep.BytesBefore
		return rep, nil
	}
	rep.CapExceeded = true
	if every <= 0 {
		every = DefaultRetention.CoarseEvery
	}
	floor := now.Unix() - int64(floorDays)*86400
	steps := []func() (int, error){
		func() (int, error) { return s.downsampleBatch(ctx, floor, batchSize, every, &rep) },
		func() (int, error) { return s.dropTracksBatch(ctx, TierCoarse, now.Unix()+1, batchSize, &rep) },
		func() (int, error) {
			n, err := s.deleteAcarsBefore(ctx, now.Unix()+1, 5000)
			rep.AcarsDeleted += n
			return int(n), err
		},
		func() (int, error) { return s.downsampleBatch(ctx, now.Unix()+1, batchSize, every, &rep) },
	}
	for _, step := range steps {
		for {
			if err := ctx.Err(); err != nil {
				return rep, err
			}
			sz, err := s.Sizes(ctx)
			if err != nil {
				return rep, err
			}
			// Measure used pages (free pages are reclaimed by the vacuum below).
			if sz.UsedBytes <= capBytes {
				return s.finishCap(ctx, rep)
			}
			n, err := step()
			if err != nil {
				return rep, err
			}
			if n == 0 {
				break
			}
		}
	}
	rep.CapUnreachable = true
	return s.finishCap(ctx, rep)
}

func (s *Store) finishCap(ctx context.Context, rep Report) (Report, error) {
	if err := s.Vacuum(ctx); err != nil {
		return rep, err
	}
	sz, err := s.Sizes(ctx)
	rep.BytesAfter = sz.Total()
	return rep, err
}
