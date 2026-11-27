package store

import (
	"context"
	"testing"
	"time"

	"github.com/BadWasabeee/flightdesk/Server/internal/trackenc"
)

func openTest(t *testing.T) *Store {
	t.Helper()
	s, err := Open(context.Background(), t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { s.Close() })
	return s
}

// addLeg stores a simulated leg ending at `end` and returns it.
func addLeg(t *testing.T, s *Store, hex string, end time.Time, prof trackenc.Profile, seed uint64) *Leg {
	t.Helper()
	pts := trackenc.Simulate(prof, 0, 42, -88, seed)
	dur := pts[len(pts)-1].T
	start := end.Unix() - dur
	for i := range pts {
		pts[i].T += start
	}
	pts = trackenc.DefaultSimplifier.Simplify(pts)
	blob, err := trackenc.Encode(start, pts)
	if err != nil {
		t.Fatal(err)
	}
	l := &Leg{Hex: hex, Callsign: "TST1", FirstSeen: start, LastSeen: end.Unix(), MinDist: 3, MaxAlt: 35000, Source: SourceArea}
	if err := s.WriteBatch(context.Background(), []LegWrite{{Leg: l, Append: blob, AddPoints: len(pts)}}, nil); err != nil {
		t.Fatal(err)
	}
	return l
}

func TestOpenPragmas(t *testing.T) {
	s := openTest(t)
	ctx := context.Background()
	if v, _ := s.AutoVacuum(ctx); v != 2 {
		t.Fatalf("auto_vacuum = %d, want 2 (incremental)", v)
	}
	if m, _ := s.JournalMode(ctx); m != "wal" {
		t.Fatalf("journal_mode = %q", m)
	}
}

func TestLegAppendInChunks(t *testing.T) {
	s := openTest(t)
	ctx := context.Background()
	base := int64(1_790_000_000)
	pts := trackenc.Simulate(trackenc.Arrival, base, 42, -88, 1)
	enc := trackenc.NewEncoder(base)
	l := &Leg{Hex: "abc123", FirstSeen: base, LastSeen: base, MinDist: -1}
	for i := 0; i < len(pts); i += 40 {
		var chunk []byte
		end := min(i+40, len(pts))
		for _, p := range pts[i:end] {
			var err error
			if chunk, err = enc.Append(chunk, p); err != nil {
				t.Fatal(err)
			}
		}
		l.LastSeen = pts[end-1].T
		if err := s.WriteBatch(ctx, []LegWrite{{Leg: l, Append: chunk, AddPoints: end - i}}, nil); err != nil {
			t.Fatal(err)
		}
	}
	got, err := s.Leg(ctx, l.ID)
	if err != nil || got == nil {
		t.Fatal(err)
	}
	// SQLite's || yields TEXT; appended tracks must stay BLOBs (length() would stop at a NUL).
	var typ string
	var n int
	if err := s.w.QueryRow("SELECT typeof(data), length(data) FROM tracks WHERE leg_id = ?", l.ID).Scan(&typ, &n); err != nil {
		t.Fatal(err)
	}
	if blob, _ := s.TrackBlob(ctx, l.ID); typ != "blob" || n != len(blob) {
		t.Fatalf("track stored as %s with length %d (blob is %d bytes)", typ, n, len(blob))
	}
	if got.Points != len(pts) || got.MinDist != -1 {
		t.Fatalf("leg %+v", got)
	}
	track, err := s.Track(ctx, got)
	if err != nil || len(track) != len(pts) {
		t.Fatalf("track %d points, err %v", len(track), err)
	}
	if track[len(track)-1] != trackenc.Quantise(pts[len(pts)-1]) {
		t.Fatal("last point differs")
	}
	if latest, _ := s.LatestLeg(ctx, "abc123", base); latest == nil || latest.ID != l.ID {
		t.Fatal("LatestLeg")
	}
}

func TestSightingsPaging(t *testing.T) {
	s := openTest(t)
	ctx := context.Background()
	var batch []*Sighting
	for i, hex := range []string{"a00003", "a00001", "a00002", "a00004"} {
		batch = append(batch, &Sighting{Hex: hex, FirstSeen: 100, LastSeen: int64(100 + i/2), Sightings: 1,
			Callsigns: []string{"AAL1", "AAL2"}, ClosestNM: 1.5, MaxAltitude: 1000, Routes: []string{}})
	}
	if err := s.WriteBatch(ctx, nil, batch); err != nil {
		t.Fatal(err)
	}
	page1, err := s.SightingsSince(ctx, 0, "", 3)
	if err != nil || len(page1) != 3 {
		t.Fatalf("%d %v", len(page1), err)
	}
	last := page1[2]
	page2, _ := s.SightingsSince(ctx, last.LastSeen, last.Hex, 3)
	if len(page2) != 1 {
		t.Fatalf("page2 %d", len(page2))
	}
	seen := map[string]bool{}
	for _, sg := range append(page1, page2...) {
		if seen[sg.Hex] {
			t.Fatal("duplicate across pages")
		}
		seen[sg.Hex] = true
	}
	if len(page1[0].Callsigns) != 2 {
		t.Fatal("callsigns not round-tripped")
	}
}

func TestRetentionTiers(t *testing.T) {
	s := openTest(t)
	ctx := context.Background()
	now := time.Unix(1_800_000_000, 0)
	day := 24 * time.Hour
	recent := addLeg(t, s, "a00001", now.Add(-10*day), trackenc.Arrival, 1)
	old := addLeg(t, s, "a00002", now.Add(-100*day), trackenc.Arrival, 2)
	ancient := addLeg(t, s, "a00003", now.Add(-800*day), trackenc.Arrival, 3)
	if err := s.PutOpenSky(ctx, old.ID, now.Unix(), []trackenc.Point{{T: 1, Track: 1}, {T: 2, Track: 2}}); err != nil {
		t.Fatal(err)
	}
	if _, err := s.InsertAcars(ctx, []AcarsMessage{
		{ID: 1, Hex: "a00001", Time: now.Add(-200 * day).Unix(), Message: []byte(`{}`)},
		{ID: 2, Hex: "a00001", Time: now.Add(-10 * day).Unix(), Message: []byte(`{}`)},
	}); err != nil {
		t.Fatal(err)
	}
	rep, err := s.ApplyRetention(ctx, now, DefaultRetention)
	if err != nil {
		t.Fatal(err)
	}
	// "old" and "ancient" are downsampled, then ancient's coarse track is dropped in the same pass.
	if rep.Downsampled != 2 || rep.TracksDropped != 1 || rep.AcarsDeleted != 1 || rep.OpenSkyDropped != 1 {
		t.Fatalf("report %+v", rep)
	}
	if rep2, _ := s.ApplyRetention(ctx, now, DefaultRetention); rep2.Any() {
		t.Fatalf("second pass not idempotent: %+v", rep2)
	}
	r, _ := s.Leg(ctx, recent.ID)
	o, _ := s.Leg(ctx, old.ID)
	a, _ := s.Leg(ctx, ancient.ID)
	if r.Tier != TierFull || o.Tier != TierCoarse || a.Tier != TierNone {
		t.Fatalf("tiers %d %d %d", r.Tier, o.Tier, a.Tier)
	}
	if o.Points >= old.Points || o.Points < 5 {
		t.Fatalf("downsampled %d -> %d points", old.Points, o.Points)
	}
	pts, _ := s.Track(ctx, o)
	for i := 1; i < len(pts)-1; i++ {
		if pts[i].T-pts[i-1].T < 300 && pts[i].Ground == pts[i-1].Ground {
			t.Fatalf("points %ds apart after downsampling", pts[i].T-pts[i-1].T)
		}
	}
	if b, _ := s.TrackBlob(ctx, ancient.ID); b != nil {
		t.Fatal("ancient track kept")
	}
	if a.Hex != "a00003" || a.Callsign != "TST1" {
		t.Fatal("leg metadata lost")
	}
}

func TestEnforceCapPrunesOldestFirst(t *testing.T) {
	s := openTest(t)
	ctx := context.Background()
	now := time.Unix(1_800_000_000, 0)
	var legs []*Leg
	// 60 days of legs, 40 per day: oldest first.
	for d := 60; d >= 1; d-- {
		for i := range 40 {
			legs = append(legs, addLeg(t, s, "a00001", now.Add(-time.Duration(d)*24*time.Hour+time.Duration(i)*time.Minute), trackenc.Departure, uint64(d*100+i)))
		}
	}
	if err := s.Vacuum(ctx); err != nil {
		t.Fatal(err)
	}
	before, _ := s.Sizes(ctx)
	limit := before.UsedBytes * 6 / 10
	rep, err := s.EnforceCap(ctx, now, limit, 7, 300)
	if err != nil {
		t.Fatal(err)
	}
	if !rep.CapExceeded || rep.Downsampled == 0 || rep.CapUnreachable {
		t.Fatalf("report %+v", rep)
	}
	after, _ := s.Sizes(ctx)
	if after.UsedBytes > limit {
		t.Fatalf("used %d > cap %d", after.UsedBytes, limit)
	}
	if after.FileBytes >= before.FileBytes {
		t.Fatalf("file did not shrink: %d -> %d (incremental vacuum)", before.FileBytes, after.FileBytes)
	}
	// Oldest first: every downsampled leg is older than every full-detail leg.
	var newestPruned, oldestKept int64 = 0, 1 << 62
	for _, l := range legs {
		got, _ := s.Leg(ctx, l.ID)
		if got.Tier > TierFull {
			newestPruned = max(newestPruned, got.LastSeen)
		} else {
			oldestKept = min(oldestKept, got.LastSeen)
		}
	}
	if newestPruned >= oldestKept {
		t.Fatalf("pruned a leg newer than one kept")
	}
	// The newest 7 days were not touched.
	if newestPruned >= now.Add(-7*24*time.Hour).Unix() {
		t.Fatal("pruned inside the floor")
	}
	// Leg rows are never deleted.
	if c, _ := s.Counts(ctx, now); c.Legs != int64(len(legs)) {
		t.Fatalf("legs %d, want %d", c.Legs, len(legs))
	}
}

func TestEnforceCapUnderCapNoop(t *testing.T) {
	s := openTest(t)
	addLeg(t, s, "a00001", time.Unix(1_800_000_000, 0), trackenc.Arrival, 1)
	rep, err := s.EnforceCap(context.Background(), time.Unix(1_800_000_000, 0), 1<<30, 7, 300)
	if err != nil || rep.CapExceeded || rep.Any() {
		t.Fatalf("%+v %v", rep, err)
	}
}

func TestEnforceCapUnreachableReported(t *testing.T) {
	s := openTest(t)
	now := time.Unix(1_800_000_000, 0)
	addLeg(t, s, "a00001", now, trackenc.Arrival, 1)
	rep, err := s.EnforceCap(context.Background(), now, 1024, 7, 300)
	if err != nil {
		t.Fatal(err)
	}
	if !rep.CapUnreachable {
		t.Fatalf("expected unreachable, got %+v", rep)
	}
}

func TestLookupsAndKV(t *testing.T) {
	s := openTest(t)
	ctx := context.Background()
	if err := s.PutLookup(ctx, "route", "SWA123", Lookup{Status: 200, Body: []byte("{}"), FetchedAt: 1, ExpiresAt: 2}); err != nil {
		t.Fatal(err)
	}
	l, err := s.GetLookup(ctx, "route", "SWA123")
	if err != nil || l == nil || l.Status != 200 {
		t.Fatalf("%+v %v", l, err)
	}
	if l, _ := s.GetLookup(ctx, "route", "NOPE"); l != nil {
		t.Fatal("phantom lookup")
	}
	if err := s.KVPut(ctx, "k", []byte("v")); err != nil {
		t.Fatal(err)
	}
	if v, ok, _ := s.KVGet(ctx, "k"); !ok || string(v) != "v" {
		t.Fatal("kv")
	}
}
