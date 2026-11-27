package trackenc

import (
	"encoding/json"
	"errors"
	"math"
	"testing"
)

func TestRoundTrip(t *testing.T) {
	base := int64(1_790_000_000)
	pts := []Point{
		{T: base, Lat: 41.88, Lon: -87.63, AltFt: 0, SpeedKt: 0, Track: TrackUnknown, Ground: true},
		{T: base + 8, Lat: 41.88012, Lon: -88.25991, AltFt: 0, SpeedKt: 12, Track: 359, Ground: true},
		{T: base + 70, Lat: 43.1, Lon: -88.2, AltFt: 1225, SpeedKt: 160, Track: 2, Ground: false},
		{T: base + 130, Lat: -33.9, Lon: 151.2, AltFt: 41000, SpeedKt: 520, Track: 180},
		{T: base + 131, Lat: 89.99999, Lon: -179.99999, AltFt: -1000, SpeedKt: 0, Track: TrackUnknown},
		{T: base + 100_000, Lat: -89.99999, Lon: 179.99999, AltFt: 60000, SpeedKt: 3999, Track: 0},
	}
	blob, err := Encode(base, pts)
	if err != nil {
		t.Fatal(err)
	}
	got, err := Decode(base, blob)
	if err != nil {
		t.Fatal(err)
	}
	if len(got) != len(pts) {
		t.Fatalf("got %d points, want %d", len(got), len(pts))
	}
	for i := range pts {
		if want := Quantise(pts[i]); got[i] != want {
			t.Errorf("point %d: got %+v want %+v", i, got[i], want)
		}
		if math.Abs(got[i].Lat-pts[i].Lat) > 0.6e-5 || math.Abs(got[i].Lon-pts[i].Lon) > 0.6e-5 {
			t.Errorf("point %d: position error too large", i)
		}
	}
	if n, _ := Count(blob); n != len(pts) {
		t.Errorf("Count = %d", n)
	}
}

func TestQuantisation(t *testing.T) {
	cases := []struct {
		name string
		in   Point
		want Point
	}{
		{"alt rounds to 25ft", Point{AltFt: 1012, Track: 10}, Point{AltFt: 1000, Track: 10}},
		{"alt clamps to int16", Point{AltFt: 2_000_000, Track: 10}, Point{AltFt: math.MaxInt16 * 25, Track: 10}},
		{"negative speed clamps", Point{SpeedKt: -5, Track: 10}, Point{SpeedKt: 0, Track: 10}},
		{"invalid track is unknown", Point{Track: 400}, Point{Track: TrackUnknown}},
		{"negative track is unknown", Point{Track: -1}, Point{Track: TrackUnknown}},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			if got := Quantise(c.in); got != c.want {
				t.Fatalf("got %+v want %+v", got, c.want)
			}
		})
	}
}

func TestTrackDeltaWraps(t *testing.T) {
	for prev := int64(0); prev < 360; prev++ {
		for cur := int64(0); cur < 360; cur++ {
			d := trackDelta(prev, cur)
			if d < -180 || d > 179 {
				t.Fatalf("delta %d out of range", d)
			}
			if got := trackApply(prev, d); got != cur {
				t.Fatalf("prev %d cur %d: got %d", prev, cur, got)
			}
		}
	}
	// 359 -> 1 is a 2 degree turn, encoded in one byte.
	if d := trackDelta(359, 1); d != 2 {
		t.Fatalf("359->1 = %d", d)
	}
	if d := trackDelta(1, 359); d != -2 {
		t.Fatalf("359->1 = %d", d)
	}
}

func TestResumeAppendsChunks(t *testing.T) {
	base := int64(1_790_000_000)
	pts := Simulate(Arrival, base, 42, -88, 7)
	whole, err := Encode(base, pts)
	if err != nil {
		t.Fatal(err)
	}
	// Encode in three chunks, resuming from the stored blob each time.
	var blob []byte
	for i, chunk := range [][]Point{pts[:10], pts[10:100], pts[100:]} {
		enc, last, ok, err := Resume(base, blob)
		if err != nil {
			t.Fatal(err)
		}
		if i > 0 && (!ok || last != Quantise(pts[len(blobPoints(t, base, blob))-1])) {
			t.Fatalf("chunk %d: resume last point mismatch", i)
		}
		var add []byte
		for _, p := range chunk {
			if add, err = enc.Append(add, p); err != nil {
				t.Fatal(err)
			}
		}
		blob = append(blob, add...)
	}
	if string(blob) != string(whole) {
		t.Fatal("chunked encoding differs from whole encoding")
	}
}

func blobPoints(t *testing.T, base int64, b []byte) []Point {
	p, err := Decode(base, b)
	if err != nil {
		t.Fatal(err)
	}
	return p
}

func TestOutOfOrderRejected(t *testing.T) {
	enc := NewEncoder(100)
	b, err := enc.Append(nil, Point{T: 200, Track: 1})
	if err != nil {
		t.Fatal(err)
	}
	if _, err := enc.Append(b, Point{T: 150, Track: 1}); !errors.Is(err, ErrOutOfOrder) {
		t.Fatalf("got %v", err)
	}
}

func TestCorruptBlob(t *testing.T) {
	for _, b := range [][]byte{{9}, {Version, 0x80}, {Version, 4, 0x80}, {Version, 4, 0, 0, 0, 0}} {
		if _, err := Decode(0, b); !errors.Is(err, ErrCorrupt) {
			t.Errorf("%v: got %v", b, err)
		}
	}
}

func TestSimplifierRules(t *testing.T) {
	s := DefaultSimplifier
	last := Point{T: 1000, Lat: 43, Lon: -88, AltFt: 10000, SpeedKt: 300, Track: 90}
	cases := []struct {
		name string
		p    Point
		keep bool
	}{
		{"same point later", Point{T: 1008, Lat: 43, Lon: -87.99, AltFt: 10000, SpeedKt: 300, Track: 90}, false},
		{"heading +3 not enough", Point{T: 1008, AltFt: 10000, Track: 93}, false},
		{"heading +4", Point{T: 1008, AltFt: 10000, Track: 94}, true},
		{"heading across north", Point{T: 1008, AltFt: 10000, Track: 86}, true},
		{"alt +200 not enough", Point{T: 1008, AltFt: 10200, Track: 90}, false},
		{"alt +225", Point{T: 1008, AltFt: 10225, Track: 90}, true},
		{"alt -225", Point{T: 1008, AltFt: 9775, Track: 90}, true},
		{"59s gap", Point{T: 1059, AltFt: 10000, Track: 90}, false},
		{"60s gap", Point{T: 1060, AltFt: 10000, Track: 90}, true},
		{"ground change", Point{T: 1008, AltFt: 0, Track: 90, Ground: true}, true},
		{"track lost", Point{T: 1008, AltFt: 10000, Track: TrackUnknown}, true},
		{"older point", Point{T: 999, AltFt: 20000, Track: 180}, false},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			if got := s.Keep(last, c.p); got != c.keep {
				t.Fatalf("Keep = %v, want %v", got, c.keep)
			}
		})
	}
}

func TestSimplifierParked(t *testing.T) {
	s := DefaultSimplifier
	parked := Point{T: 0, Lat: 41.97, Lon: -87.9, Ground: true, Track: TrackUnknown}
	p := parked
	p.T = 300
	if s.Keep(parked, p) {
		t.Fatal("parked aircraft stored after 5 min")
	}
	p.T = 600
	if !s.Keep(parked, p) {
		t.Fatal("parked heartbeat missing after 10 min")
	}
	taxi := Point{T: 60, Lat: 41.975, Lon: -87.9, Ground: true, SpeedKt: 15, Track: 10}
	if !s.Keep(parked, taxi) {
		t.Fatal("taxiing aircraft not stored after 60 s")
	}
}

func TestSimplifyReducesAndKeepsEnds(t *testing.T) {
	for _, prof := range []Profile{Arrival, Departure, Overflight} {
		pts := Simulate(prof, 1_790_000_000, 42, -88, 1)
		kept := DefaultSimplifier.Simplify(pts)
		if kept[0] != pts[0] || kept[len(kept)-1] != pts[len(pts)-1] {
			t.Fatalf("%s: ends not kept", prof.Name)
		}
		if len(kept) >= len(pts)/2 {
			t.Fatalf("%s: simplify kept %d of %d", prof.Name, len(kept), len(pts))
		}
		// Never more than MaxGap between airborne stored points (one poll of slack).
		for i := 1; i < len(kept); i++ {
			if !kept[i].Ground && !kept[i-1].Ground && kept[i].T-kept[i-1].T > DefaultSimplifier.MaxGap+SampleEvery {
				t.Fatalf("%s: gap of %ds", prof.Name, kept[i].T-kept[i-1].T)
			}
		}
	}
}

func TestDownsample(t *testing.T) {
	pts := Simulate(Arrival, 1_790_000_000, 42, -88, 3)
	full := DefaultSimplifier.Simplify(pts)
	ds := Downsample(full, 300)
	if ds[0] != full[0] || ds[len(ds)-1] != full[len(full)-1] {
		t.Fatal("ends not kept")
	}
	landing := false
	for i := 1; i < len(ds); i++ {
		if ds[i].Ground && !ds[i-1].Ground {
			landing = true
		}
	}
	if !landing {
		t.Fatal("landing transition dropped")
	}
	durationMin := (full[len(full)-1].T - full[0].T) / 60
	if int64(len(ds)) > durationMin/5+4 {
		t.Fatalf("downsampled to %d points for %d minutes", len(ds), durationMin)
	}
}

// Storage per stored point for each profile, logged so `go test -v` shows the numbers the
// README estimate is built from.
func TestStorageFigures(t *testing.T) {
	for _, prof := range []Profile{Arrival, Departure, Overflight} {
		var raw, kept, bytes, jsonBytes int
		const legs = 50
		for seed := range uint64(legs) {
			pts := Simulate(prof, 1_790_000_000, 42, -88, seed)
			k := DefaultSimplifier.Simplify(pts)
			b, err := Encode(pts[0].T, k)
			if err != nil {
				t.Fatal(err)
			}
			j, _ := json.Marshal(k)
			raw += len(pts)
			kept += len(k)
			bytes += len(b)
			jsonBytes += len(j)
		}
		t.Logf("%-10s raw %4d pts/leg -> kept %4d pts/leg, %5.2f B/pt, %5d B/leg (JSON would be %d B/leg)",
			prof.Name, raw/legs, kept/legs, float64(bytes)/float64(kept), bytes/legs, jsonBytes/legs)
	}
}
