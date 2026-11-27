package tracker

import (
	"context"
	"fmt"
	"math/rand/v2"
	"os"
	"slices"
	"testing"
	"time"

	"github.com/BadWasabeee/flightdesk/Server/internal/adsb"
	"github.com/BadWasabeee/flightdesk/Server/internal/store"
	"github.com/BadWasabeee/flightdesk/Server/internal/trackenc"
)

// TestStorageEstimate simulates busy days end to end (tracker -> SQLite) and reports the real
// database growth per day, which is what the README's storage estimate quotes. It takes a few
// seconds, so it only runs when asked:
//
//	FLIGHTDESK_STORAGE_ESTIMATE=1 go test ./internal/tracker -run StorageEstimate -v
func TestStorageEstimate(t *testing.T) {
	if os.Getenv("FLIGHTDESK_STORAGE_ESTIMATE") == "" {
		t.Skip("set FLIGHTDESK_STORAGE_ESTIMATE=1 to run")
	}
	const (
		days       = 3
		legsPerDay = 1000 // ~800 unique airframes, some flying more than one leg through the area
		poolSize   = 2500 // airframes that visit the area over time
	)
	mix := []struct {
		p     trackenc.Profile
		share float64
	}{{trackenc.Arrival, 0.35}, {trackenc.Departure, 0.35}, {trackenc.Overflight, 0.30}}

	st := openStore(t, t.TempDir())
	ctx := context.Background()
	tr := New(Config{CenterLat: 42.5, CenterLon: -88, RadiusNM: 250}, st, nil, nil)
	r := rand.New(rand.NewPCG(1, 2))
	day0 := int64(1_790_000_000)

	type obs struct {
		hex string
		cs  string
		p   trackenc.Point
	}
	var prevUsed int64
	for d := range days {
		var all []obs
		dayStart := day0 + int64(d)*86400
		unique := map[string]bool{}
		for i := range legsPerDay {
			x, prof := r.Float64(), mix[len(mix)-1].p
			for _, m := range mix {
				if x < m.share {
					prof = m.p
					break
				}
				x -= m.share
			}
			hex := fmt.Sprintf("a%05x", r.IntN(poolSize))
			unique[hex] = true
			start := dayStart + r.Int64N(86400)
			for _, p := range trackenc.Simulate(prof, start, 42+r.Float64(), -88.5+r.Float64(), uint64(d*legsPerDay+i)) {
				all = append(all, obs{hex, fmt.Sprintf("AAL%d", 100+r.IntN(900)), p})
			}
		}
		slices.SortFunc(all, func(a, b obs) int { return int(a.p.T - b.p.T) })
		// Feed in 8-second polls; flush every minute like the poller.
		lastFlush := dayStart
		for i := 0; i < len(all); {
			pollEnd := all[i].p.T + trackenc.SampleEvery
			batch := map[string]adsb.Flight{}
			for ; i < len(all) && all[i].p.T < pollEnd; i++ {
				o := all[i]
				tk := float64(o.p.Track)
				batch[o.hex] = adsb.Flight{ID: o.hex, Callsign: o.cs, Reg: "N" + o.hex[1:], TypeCode: "B738", OwnOp: "Example Airlines",
					Altitude: o.p.AltFt, OnGround: o.p.Ground, Speed: float64(o.p.SpeedKt), Track: &tk,
					Lat: o.p.Lat, Lon: o.p.Lon, PositionTime: float64(o.p.T)}
			}
			list := make([]adsb.Flight, 0, len(batch))
			for _, f := range batch {
				list = append(list, f)
			}
			tr.Observe(ctx, list, store.SourceArea)
			if pollEnd-lastFlush >= 60 {
				if err := tr.Flush(ctx, time.Unix(pollEnd, 0)); err != nil {
					t.Fatal(err)
				}
				lastFlush = pollEnd
			}
		}
		if err := tr.Flush(ctx, time.Unix(dayStart+86400+3600, 0)); err != nil {
			t.Fatal(err)
		}
		_ = st.Vacuum(ctx)
		sz, _ := st.Sizes(ctx)
		c, _ := st.Counts(ctx, time.Unix(dayStart+86400, 0))
		t.Logf("day %d: %d unique airframes, %d observations -> used %.2f MB total (+%.2f MB), legs %d, points %d (%.1f/leg), track blobs %.2f MB (%.1f B/pt), sightings %d",
			d+1, len(unique), len(all), mb(sz.UsedBytes), mb(sz.UsedBytes-prevUsed), c.Legs, c.TrackPoints,
			float64(c.TrackPoints)/float64(c.Legs), mb(c.TrackBytes), float64(c.TrackBytes)/float64(c.TrackPoints), c.Sightings)
		prevUsed = sz.UsedBytes
	}
	// The long-term tier: downsample everything and measure again.
	rep, err := st.ApplyRetention(ctx, time.Unix(day0+int64(days+91)*86400, 0), store.Retention{DetailDays: 90, CoarseDays: 730, AcarsDays: 180})
	if err != nil {
		t.Fatal(err)
	}
	sz, _ := st.Sizes(ctx)
	c, _ := st.Counts(ctx, time.Unix(day0, 0))
	t.Logf("after downsampling to 1 pt/5 min: used %.2f MB (%.2f MB/day), file %.2f MB, free %.2f MB, %d legs downsampled, %.1f pts/leg, track blobs %.2f MB",
		mb(sz.UsedBytes), mb(sz.UsedBytes)/days, mb(sz.FileBytes), mb(sz.FreeBytes), rep.Downsampled, float64(c.TrackPoints)/float64(c.Legs), mb(c.TrackBytes))
}

func mb(b int64) float64 { return float64(b) / (1 << 20) }
