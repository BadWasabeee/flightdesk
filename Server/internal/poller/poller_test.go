package poller

import (
	"context"
	"errors"
	"fmt"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/BadWasabeee/flightdesk/Server/internal/store"
	"github.com/BadWasabeee/flightdesk/Server/internal/tracker"
	"github.com/BadWasabeee/flightdesk/Server/internal/upstream"
)

type fakeFeeds struct {
	mu        sync.Mutex
	fiStatus  int
	paths     []string
	hexGround map[string]bool // hex -> on ground; absent = not found
}

func (f *fakeFeeds) handler() http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		f.mu.Lock()
		defer f.mu.Unlock()
		f.paths = append(f.paths, r.URL.Path)
		now := float64(time.Now().Unix())
		switch {
		case strings.HasPrefix(r.URL.Path, "/fi/v2/hex/"):
			var recs []string
			for _, h := range strings.Split(strings.TrimPrefix(r.URL.Path, "/fi/v2/hex/"), ",") {
				if g, ok := f.hexGround[h]; ok {
					alt := `35000`
					if g {
						alt = `"ground"`
					}
					recs = append(recs, fmt.Sprintf(`{"hex":%q,"flight":"BAW1","alt_baro":%s,"lat":51.5,"lon":-0.4,"track":90,"gs":400,"seen_pos":1}`, h, alt))
				}
			}
			fmt.Fprintf(w, `{"now":%f,"ac":[%s]}`, now, strings.Join(recs, ","))
		case strings.HasPrefix(r.URL.Path, "/fi/"):
			if f.fiStatus != 0 {
				w.WriteHeader(f.fiStatus)
				return
			}
			fmt.Fprintf(w, `{"now":%f,"aircraft":[{"hex":"a1cfb7","flight":"N2159Q","alt_baro":1400,"lat":43.1,"lon":-88.3,"track":315,"gs":69,"seen_pos":0.2}]}`, now)
		case strings.HasPrefix(r.URL.Path, "/lol/"):
			fmt.Fprintf(w, `{"now":%f,"ac":[{"hex":"a00002","alt_baro":5000,"lat":43.0,"lon":-88.0,"seen_pos":1}]}`, now*1000)
		default:
			http.NotFound(w, r)
		}
	})
}

func (f *fakeFeeds) calls(prefix string) int {
	f.mu.Lock()
	defer f.mu.Unlock()
	n := 0
	for _, p := range f.paths {
		if strings.HasPrefix(p, prefix) {
			n++
		}
	}
	return n
}

func setup(t *testing.T, ff *fakeFeeds, cfg Config) (*Poller, *store.Store) {
	t.Helper()
	srv := httptest.NewServer(ff.handler())
	t.Cleanup(srv.Close)
	client := upstream.New("test", 5*time.Second, map[upstream.Service]upstream.Policy{
		upstream.AdsbFi: {}, upstream.AdsbLol: {DailyLimit: 500, Reserve: 60}})
	feeds := NewFeeds(client, upstream.Endpoints{AdsbFi: srv.URL + "/fi", AdsbLol: srv.URL + "/lol"})
	st, err := store.Open(context.Background(), t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { st.Close() })
	tr := tracker.New(tracker.Config{CenterLat: cfg.CenterLat, CenterLon: cfg.CenterLon, RadiusNM: float64(cfg.RadiusNM)}, st, nil, nil)
	return New(cfg, feeds, tr, st, nil), st
}

func TestAreaPollAndFallback(t *testing.T) {
	ff := &fakeFeeds{}
	p, _ := setup(t, ff, Config{CenterLat: 41.88, CenterLon: -87.63, RadiusNM: 50})
	ctx := context.Background()
	p.PollArea(ctx)
	s := p.Snapshot()
	if s == nil || s.Source != upstream.AdsbFi || len(s.Flights) != 1 || s.Flights[0].ID != "a1cfb7" {
		t.Fatalf("snapshot %+v", s)
	}
	if ff.calls("/fi/v2/lat/41.88/lon/-87.63/dist/50") != 1 {
		t.Fatalf("unexpected request paths %v", ff.paths)
	}
	// adsb.fi fails: fall back to adsb.lol once, then adsb.fi is benched and adsb.lol spaced.
	ff.mu.Lock()
	ff.fiStatus = 503
	ff.mu.Unlock()
	p.PollArea(ctx)
	if s := p.Snapshot(); s.Source != upstream.AdsbLol || s.Flights[0].ID != "a00002" {
		t.Fatalf("fallback snapshot %+v", s)
	}
	p.PollArea(ctx) // adsb.fi benched, adsb.lol inside its spacing: no requests at all
	if ff.calls("/fi/v2/lat") != 2 || ff.calls("/lol/") != 1 {
		t.Fatalf("fi %d lol %d", ff.calls("/fi/v2/lat"), ff.calls("/lol/"))
	}
	if h := p.Health(); h.ConsecutiveFailures != 1 || h.LastError == "" {
		t.Fatalf("health %+v", h)
	}
}

func TestWatchesBatchAndStop(t *testing.T) {
	ff := &fakeFeeds{hexGround: map[string]bool{"400001": false, "400002": false}}
	p, st := setup(t, ff, Config{MaxWatches: 3})
	ctx := context.Background()
	now := time.Now()
	p.SetClock(func() time.Time { return now })
	for _, h := range []string{"400001", "400002", "400003"} {
		if _, _, err := p.AddWatch(ctx, h); err != nil {
			t.Fatal(err)
		}
	}
	if _, _, err := p.AddWatch(ctx, "400004"); !errors.Is(err, ErrWatchLimit) {
		t.Fatalf("cap not enforced: %v", err)
	}
	if _, n, err := p.AddWatch(ctx, "400001"); err != nil || n != 3 {
		t.Fatal("re-adding an existing watch should succeed")
	}
	p.PollWatches(ctx)
	if n := ff.calls("/fi/v2/hex/"); n != 1 {
		t.Fatalf("%d hex requests, want 1 batched", n)
	}
	if !strings.Contains(strings.Join(ff.paths, " "), "/fi/v2/hex/400001,400002,400003") {
		t.Fatalf("paths %v", ff.paths)
	}
	// 400001 lands; 400003 has never been seen and goes missing for 31 minutes.
	ff.mu.Lock()
	ff.hexGround["400001"] = true
	ff.mu.Unlock()
	now = now.Add(31 * time.Minute)
	ff.mu.Lock()
	ff.hexGround["400002"] = false
	ff.mu.Unlock()
	p.PollWatches(ctx)
	got := p.Watches()
	if len(got) != 1 || got[0].Hex != "400002" {
		t.Fatalf("watches after landing/missing: %+v", got)
	}
	// Watches survive a restart.
	p2 := New(Config{MaxWatches: 3}, p.feeds, p.tr, st, nil)
	p2.SetClock(func() time.Time { return now })
	p2.loadWatches(ctx)
	if w := p2.Watches(); len(w) != 1 || w[0].Hex != "400002" {
		t.Fatalf("restored %+v", w)
	}
}

func TestWatchUsesAreaSnapshotWithoutRequest(t *testing.T) {
	ff := &fakeFeeds{}
	p, _ := setup(t, ff, Config{CenterLat: 41.88, CenterLon: -87.63, RadiusNM: 50})
	ctx := context.Background()
	p.PollArea(ctx)
	if _, _, err := p.AddWatch(ctx, "a1cfb7"); err != nil {
		t.Fatal(err)
	}
	p.PollWatches(ctx)
	if n := ff.calls("/fi/v2/hex/"); n != 0 {
		t.Fatalf("watch on an in-area flight made %d requests", n)
	}
	if w := p.Watches(); len(w) != 1 || w[0].LastSeen.IsZero() || !w[0].SeenAirborne {
		t.Fatalf("watch not updated from the snapshot: %+v", w)
	}
}
