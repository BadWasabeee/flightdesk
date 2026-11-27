package tracker

import (
	"context"
	"testing"
	"time"

	"github.com/BadWasabeee/flightdesk/Server/internal/adsb"
	"github.com/BadWasabeee/flightdesk/Server/internal/store"
	"github.com/BadWasabeee/flightdesk/Server/internal/trackenc"
)

func openStore(t *testing.T, dir string) *store.Store {
	t.Helper()
	s, err := store.Open(context.Background(), dir)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { s.Close() })
	return s
}

func flightAt(hex, cs string, p trackenc.Point) adsb.Flight {
	tr := float64(p.Track)
	f := adsb.Flight{ID: hex, Callsign: cs, Reg: "N1", TypeCode: "B738", Altitude: p.AltFt, Speed: float64(p.SpeedKt),
		Lat: p.Lat, Lon: p.Lon, OnGround: p.Ground, PositionTime: float64(p.T), OwnOp: "Test Air"}
	if p.HasTrack() {
		f.Track = &tr
	}
	return f
}

func cfg() Config { return Config{CenterLat: 42, CenterLon: -88, RadiusNM: 250} }

func TestTrackerSimplifiesAndFlushes(t *testing.T) {
	st := openStore(t, t.TempDir())
	tr := New(cfg(), st, func(cs string) (string, string, bool) { return "ORD", "DEN", true }, nil)
	ctx := context.Background()
	base := int64(1_790_000_000)
	pts := trackenc.Simulate(trackenc.Arrival, base, 42, -88, 5)
	for i, p := range pts {
		tr.Observe(ctx, []adsb.Flight{flightAt("abc123", "UAL1", p)}, store.SourceArea)
		if i%15 == 0 { // flush every two minutes of polls
			if err := tr.Flush(ctx, time.Unix(p.T, 0)); err != nil {
				t.Fatal(err)
			}
		}
	}
	act, ok, err := tr.ActiveTrack(ctx, "abc123")
	if err != nil || !ok {
		t.Fatal(err)
	}
	want := trackenc.DefaultSimplifier.Simplify(pts)
	if len(act.Points) != len(want) {
		t.Fatalf("active track %d points, want %d (simplified from %d)", len(act.Points), len(want), len(pts))
	}
	// After the leg gap the leg closes and everything is in the database.
	last := pts[len(pts)-1].T
	if err := tr.Flush(ctx, time.Unix(last+31*60, 0)); err != nil {
		t.Fatal(err)
	}
	if _, ok, _ := tr.ActiveTrack(ctx, "abc123"); ok {
		t.Fatal("leg still active after gap")
	}
	leg, _ := st.LatestLeg(ctx, "abc123", 0)
	if leg == nil || leg.Callsign != "UAL1" || leg.Origin != "ORD" || leg.Dest != "DEN" || leg.MaxAlt < 34000 {
		t.Fatalf("leg %+v", leg)
	}
	stored, _ := st.Track(ctx, leg)
	if len(stored) != len(want) || leg.Points != len(want) {
		t.Fatalf("stored %d points (leg says %d), want %d", len(stored), leg.Points, len(want))
	}
	if stored[len(stored)-1].T != last {
		t.Fatal("track does not end at the last observation")
	}
	sg, _ := st.Sighting(ctx, "abc123")
	if sg == nil || sg.Sightings != 1 || len(sg.Callsigns) != 1 || sg.AirlineICAO != "UAL" || len(sg.Routes) != 1 || sg.Routes[0] != "ORD-DEN" {
		t.Fatalf("sighting %+v", sg)
	}
}

func TestTrackerNewLegAfterGapAndTurnaround(t *testing.T) {
	st := openStore(t, t.TempDir())
	tr := New(cfg(), st, nil, nil)
	ctx := context.Background()
	base := int64(1_790_000_000)
	obs := func(dt int64, alt int, ground bool) {
		p := trackenc.Point{T: base + dt, Lat: 42, Lon: -88, AltFt: alt, Track: 90, Ground: ground, SpeedKt: 200}
		tr.Observe(ctx, []adsb.Flight{flightAt("abc123", "SWA1", p)}, store.SourceArea)
	}
	obs(0, 5000, false)
	obs(60, 0, true)                   // landed
	obs(60+11*60, 0, true)             // 11 min turnaround
	obs(60+12*60, 800, false)          // departs again: new leg
	obs(60+12*60+31*60+1, 9000, false) // 31 min unseen: new leg
	if err := tr.Flush(ctx, time.Unix(base+60+12*60+31*60+2, 0)); err != nil {
		t.Fatal(err)
	}
	legs, _ := st.Legs(ctx, store.LegsQuery{Hex: "abc123"})
	if len(legs) != 3 {
		t.Fatalf("got %d legs, want 3", len(legs))
	}
	sg, _ := st.Sighting(ctx, "abc123")
	if sg.Sightings != 2 {
		t.Fatalf("visits %d, want 2 (only the 31-minute gap is a new visit)", sg.Sightings)
	}
}

func TestTrackerResumesAfterRestart(t *testing.T) {
	dir := t.TempDir()
	st := openStore(t, dir)
	ctx := context.Background()
	base := int64(1_790_000_000)
	pts := trackenc.Simulate(trackenc.Overflight, base, 42, -88, 9)
	half := len(pts) / 2
	tr := New(cfg(), st, nil, nil)
	for _, p := range pts[:half] {
		tr.Observe(ctx, []adsb.Flight{flightAt("def456", "DAL9", p)}, store.SourceArea)
	}
	if err := tr.Flush(ctx, time.Unix(pts[half-1].T, 0)); err != nil {
		t.Fatal(err)
	}
	// "Restart": a new tracker resumes the active leg.
	tr2 := New(cfg(), st, nil, nil)
	if err := tr2.Resume(ctx, time.Unix(pts[half].T, 0)); err != nil {
		t.Fatal(err)
	}
	for _, p := range pts[half:] {
		tr2.Observe(ctx, []adsb.Flight{flightAt("def456", "DAL9", p)}, store.SourceArea)
	}
	if err := tr2.Flush(ctx, time.Unix(pts[len(pts)-1].T+3600, 0)); err != nil {
		t.Fatal(err)
	}
	legs, _ := st.Legs(ctx, store.LegsQuery{Hex: "def456"})
	if len(legs) != 1 {
		t.Fatalf("restart split the leg: %d legs", len(legs))
	}
	got, err := st.Track(ctx, legs[0])
	if err != nil {
		t.Fatal(err)
	}
	if got[0].T != pts[0].T || got[len(got)-1].T != pts[len(pts)-1].T {
		t.Fatal("resumed track does not span the whole leg")
	}
}

func TestTrackerRejectsGlitch(t *testing.T) {
	st := openStore(t, t.TempDir())
	tr := New(cfg(), st, nil, nil)
	ctx := context.Background()
	p := trackenc.Point{T: 1000, Lat: 42, Lon: -88, AltFt: 30000, Track: 90, SpeedKt: 450}
	tr.Observe(ctx, []adsb.Flight{flightAt("abc123", "X1", p)}, store.SourceArea)
	bad := p
	bad.T, bad.Lat = 1008, 45 // 180 nm in 8 s
	tr.Observe(ctx, []adsb.Flight{flightAt("abc123", "X1", bad)}, store.SourceArea)
	act, _, _ := tr.ActiveTrack(ctx, "abc123")
	for _, q := range act.Points {
		if q.Lat > 44 {
			t.Fatal("glitch stored")
		}
	}
}

func TestWatchSourceNoSighting(t *testing.T) {
	st := openStore(t, t.TempDir())
	tr := New(cfg(), st, nil, nil)
	ctx := context.Background()
	p := trackenc.Point{T: 1000, Lat: 42, Lon: -88, AltFt: 30000, Track: 90}
	tr.Observe(ctx, []adsb.Flight{flightAt("abc123", "X1", p)}, store.SourceWatch)
	if err := tr.Flush(ctx, time.Unix(1000, 0)); err != nil {
		t.Fatal(err)
	}
	if sg, _ := st.Sighting(ctx, "abc123"); sg != nil {
		t.Fatal("watched flight logged as a sighting")
	}
	leg, _ := st.LatestLeg(ctx, "abc123", 0)
	if leg == nil || leg.Source != store.SourceWatch {
		t.Fatalf("leg %+v", leg)
	}
}
