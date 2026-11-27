package api

import (
	"compress/gzip"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/BadWasabeee/flightdesk/Server/internal/adsb"
	"github.com/BadWasabeee/flightdesk/Server/internal/config"
	"github.com/BadWasabeee/flightdesk/Server/internal/poller"
	"github.com/BadWasabeee/flightdesk/Server/internal/store"
	"github.com/BadWasabeee/flightdesk/Server/internal/trackenc"
	"github.com/BadWasabeee/flightdesk/Server/internal/tracker"
	"github.com/BadWasabeee/flightdesk/Server/internal/upstream"
)

const testToken = "9c4e2a7f1b3d5e8a0c6f2b4d7e9a1c3f5b8d0e2a4c6f8b1d3e5a7c9f0b2d4e6a"

// fakeUpstream imitates every upstream service and counts requests per path.
type fakeUpstream struct {
	mu    sync.Mutex
	hits  map[string]int
	delay time.Duration
	now   func() time.Time
}

func (f *fakeUpstream) count(path string) int {
	f.mu.Lock()
	defer f.mu.Unlock()
	return f.hits[path]
}

func (f *fakeUpstream) countPrefix(prefix string) int {
	f.mu.Lock()
	defer f.mu.Unlock()
	n := 0
	for p, c := range f.hits {
		if strings.HasPrefix(p, prefix) {
			n += c
		}
	}
	return n
}

func (f *fakeUpstream) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	f.mu.Lock()
	f.hits[r.URL.Path]++
	delay := f.delay
	f.mu.Unlock()
	if delay > 0 {
		time.Sleep(delay)
	}
	now := f.now()
	p := r.URL.Path
	switch {
	case strings.HasPrefix(p, "/fi/v2/lat/"):
		// Area query: one aircraft near the centre, one farther away (outside a small device radius),
		// one on the ground.
		fmt.Fprintf(w, `{"now":%d,"aircraft":[
			{"hex":"a1cfb7","flight":"N2159Q  ","r":"N2159Q","t":"P28A","alt_baro":1400,"gs":69.3,"track":315,"baro_rate":1216,"squawk":"1200","lat":43.10,"lon":-88.28,"seen_pos":0.2},
			{"hex":"a00002","flight":"SWA1","alt_baro":30000,"gs":450,"track":90,"lat":43.6,"lon":-88.26,"seen_pos":0.5},
			{"hex":"a00003","flight":"DAL5","alt_baro":"ground","gs":0,"lat":42.95,"lon":-87.9,"seen_pos":0.5}]}`, now.Unix())
	case strings.HasPrefix(p, "/lol/"):
		w.WriteHeader(503)
	case strings.HasPrefix(p, "/opensky/tracks/all"):
		// Departed from the ground an hour ago; OpenSky's track runs up to a minute ago.
		start, end := now.Add(-time.Hour).Unix(), now.Add(-time.Minute).Unix()
		fmt.Fprintf(w, `{"icao24":"abc123","callsign":"UAL1","startTime":%d,"endTime":%d,"path":[[%d,41.97,-87.9,0,90,true],[%d,42.0,-87.8,1500,90,false],[%d,43.5,-86.5,30000,45,false]]}`,
			start, end, start, start+60, end)
	case strings.HasPrefix(p, "/adsbdb/callsign/UNKNOWN"):
		w.WriteHeader(404)
		io.WriteString(w, `{"response":"unknown callsign"}`)
	case strings.HasPrefix(p, "/adsbdb/callsign/"):
		io.WriteString(w, `{"response":{"flightroute":{"callsign":"UAL1","callsign_iata":"UA1","airline":{"name":"United Airlines","iata":"UA"},
			"origin":{"iata_code":"ORD","icao_code":"KORD","municipality":"Chicago","latitude":41.97,"longitude":-87.9},
			"destination":{"iata_code":"DEN","icao_code":"KDEN","municipality":"Denver","latitude":39.86,"longitude":-104.67}}}}`)
	case strings.HasPrefix(p, "/adsbdb/aircraft/"):
		io.WriteString(w, `{"response":{"aircraft":{"type":"737-824","manufacturer":"Boeing","registered_owner":"United Airlines"}}}`)
	case p == "/af/airframes/icao/ABC123":
		io.WriteString(w, `{"id":555,"tail":"N12345","icao":"ABC123"}`)
	case strings.HasPrefix(p, "/af/airframes/icao/"):
		// Unknown aircraft: Airframes answers with an empty body.
	case p == "/af/airframes/555":
		fmt.Fprintf(w, `{"id":555,"icao":"ABC123","flights":[{"id":9001,"flight":"UAL1","updatedAt":%q},{"id":9000,"flight":"UAL2","updatedAt":%q}]}`,
			now.Add(-10*time.Minute).UTC().Format(time.RFC3339), now.Add(-30*time.Hour).UTC().Format(time.RFC3339))
	case p == "/af/flights/9001":
		fmt.Fprintf(w, `{"id":"9001","flight":"UAL1","messages":[{"id":1,"timestamp":%q,"label":"H1","text":"hello"},{"id":2,"timestamp":%q,"label":"_d","text":""}]}`,
			now.Add(-5*time.Minute).UTC().Format(time.RFC3339Nano), now.Add(-4*time.Minute).UTC().Format(time.RFC3339))
	case p == "/wx/metar" || p == "/wx/taf":
		var recs []string
		for _, id := range strings.Split(r.URL.Query().Get("ids"), ",") {
			if id != "KNON" { // a station without reports
				recs = append(recs, fmt.Sprintf(`{"icaoId":%q,"rawOb":"%s 271453Z 27010KT 10SM CLR"}`, id, id))
			}
		}
		if len(recs) == 0 {
			w.WriteHeader(204)
			return
		}
		io.WriteString(w, "["+strings.Join(recs, ",")+"]")
	default:
		http.NotFound(w, r)
	}
}

type harness struct {
	srv  *Server
	h    http.Handler
	up   *fakeUpstream
	st   *store.Store
	tr   *tracker.Tracker
	poll *poller.Poller
	ts   *httptest.Server
}

func newHarness(t *testing.T, mutate ...func(*config.Config)) *harness {
	t.Helper()
	up := &fakeUpstream{hits: map[string]int{}, now: time.Now}
	ts := httptest.NewServer(up)
	t.Cleanup(ts.Close)
	ep := upstream.Endpoints{AdsbFi: ts.URL + "/fi", AdsbLol: ts.URL + "/lol", OpenSky: ts.URL + "/opensky",
		Adsbdb: ts.URL + "/adsbdb", Airframes: ts.URL + "/af", AviationWeather: ts.URL + "/wx"}
	zero := map[upstream.Service]upstream.Policy{}
	for _, s := range upstream.Services {
		zero[s] = upstream.Policy{}
	}
	zero[upstream.OpenSky] = upstream.Policy{DailyLimit: 400, Reserve: 40}
	client := upstream.New("test", 5*time.Second, zero)
	st, err := store.Open(context.Background(), t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { st.Close() })
	cfg := config.Defaults()
	cfg.Token = testToken
	cfg.CenterLat, cfg.CenterLon, cfg.RadiusNM = 43.08, -88.26, 50
	for _, m := range mutate {
		m(&cfg)
	}
	routes := NewRouteMemo(100)
	tr := tracker.New(tracker.Config{CenterLat: cfg.CenterLat, CenterLon: cfg.CenterLon, RadiusNM: float64(cfg.RadiusNM)}, st, routes.Lookup, nil)
	feeds := poller.NewFeeds(client, ep)
	pl := poller.New(poller.Config{CenterLat: cfg.CenterLat, CenterLon: cfg.CenterLon, RadiusNM: cfg.RadiusNM, Interval: 8 * time.Second, MaxWatches: 2}, feeds, tr, st, nil)
	srv := New(Deps{Config: cfg, Store: st, Client: client, Endpoints: ep, Feeds: feeds, Poller: pl, Tracker: tr, Routes: routes, Version: "test"})
	return &harness{srv: srv, h: srv.Handler(), up: up, st: st, tr: tr, poll: pl, ts: ts}
}

func (h *harness) do(t *testing.T, method, target string, hdr ...string) *httptest.ResponseRecorder {
	t.Helper()
	req := httptest.NewRequest(method, target, nil)
	req.Header.Set("Authorization", "Bearer "+testToken)
	for i := 0; i+1 < len(hdr); i += 2 {
		if hdr[i+1] == "" {
			req.Header.Del(hdr[i])
		} else {
			req.Header.Set(hdr[i], hdr[i+1])
		}
	}
	rec := httptest.NewRecorder()
	h.h.ServeHTTP(rec, req)
	return rec
}

func decode[T any](t *testing.T, rec *httptest.ResponseRecorder) T {
	t.Helper()
	var v T
	body := rec.Body.Bytes()
	if rec.Header().Get("Content-Encoding") == "gzip" {
		zr, err := gzip.NewReader(rec.Body)
		if err != nil {
			t.Fatal(err)
		}
		body, _ = io.ReadAll(zr)
	}
	if err := json.Unmarshal(body, &v); err != nil {
		t.Fatalf("decode %q: %v", body, err)
	}
	return v
}

func TestAuth(t *testing.T) {
	h := newHarness(t)
	if rec := h.do(t, "GET", "/healthz", "Authorization", ""); rec.Code != 200 {
		t.Fatalf("healthz without token: %d", rec.Code)
	}
	cases := []struct {
		name, auth string
		want       int
	}{
		{"missing", "", 401},
		{"wrong", "Bearer " + strings.Repeat("x", 64), 401},
		{"prefix of token", "Bearer " + testToken[:32], 401},
		{"token plus suffix", "Bearer " + testToken + "x", 401},
		{"basic scheme", "Basic " + testToken, 401},
		{"right", "Bearer " + testToken, 200},
		{"lowercase scheme", "bearer " + testToken, 200},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			rec := h.do(t, "GET", "/v1/watch", "Authorization", c.auth)
			if rec.Code != c.want {
				t.Fatalf("got %d want %d", rec.Code, c.want)
			}
			if c.want == 401 && rec.Header().Get("WWW-Authenticate") == "" {
				t.Fatal("no WWW-Authenticate")
			}
		})
	}
	// Unknown paths need the token too (no route enumeration).
	if rec := h.do(t, "GET", "/v1/nope", "Authorization", ""); rec.Code != 401 {
		t.Fatalf("unknown path without token: %d", rec.Code)
	}
}

func TestFailedAuthLockout(t *testing.T) {
	h := newHarness(t)
	for range 10 {
		h.do(t, "GET", "/v1/watch", "Authorization", "Bearer wrong")
	}
	if rec := h.do(t, "GET", "/v1/watch"); rec.Code != 429 {
		t.Fatalf("after 10 failures even the right token should be locked out briefly, got %d", rec.Code)
	}
	if rec := h.do(t, "GET", "/v1/watch", "X-Real-IP", "198.51.100.7"); rec.Code != 429 {
		// httptest's RemoteAddr is 192.0.2.1 (not loopback), so X-Real-IP is ignored.
		t.Fatalf("spoofed X-Real-IP from a non-proxy peer bypassed lockout: %d", rec.Code)
	}
}

func TestRateLimit(t *testing.T) {
	h := newHarness(t, func(c *config.Config) { c.RateLimitPerMin = 60 })
	limited := false
	for range 40 {
		if rec := h.do(t, "GET", "/v1/watch"); rec.Code == 429 {
			limited = true
			if rec.Header().Get("Retry-After") == "" {
				t.Fatal("429 without Retry-After")
			}
			break
		}
	}
	if !limited {
		t.Fatal("never rate limited")
	}
}

func TestClientIPTrustsOnlyLoopbackProxy(t *testing.T) {
	r := httptest.NewRequest("GET", "/", nil)
	r.RemoteAddr = "127.0.0.1:5000"
	r.Header.Set("X-Forwarded-For", "203.0.113.9, 198.51.100.2")
	if ip := clientIP(r, true); ip != "198.51.100.2" {
		t.Fatalf("got %s", ip)
	}
	r.Header.Set("X-Real-IP", "203.0.113.5")
	if ip := clientIP(r, true); ip != "203.0.113.5" {
		t.Fatalf("got %s", ip)
	}
	if ip := clientIP(r, false); ip != "127.0.0.1" {
		t.Fatalf("untrusted: got %s", ip)
	}
	r.RemoteAddr = "192.0.2.1:5000"
	if ip := clientIP(r, true); ip != "192.0.2.1" {
		t.Fatalf("non-loopback peer: got %s", ip)
	}
}

func TestInputValidation(t *testing.T) {
	h := newHarness(t)
	bad := []string{
		"/v1/nearby",
		"/v1/nearby?lat=43&lon=",
		"/v1/nearby?lat=91&lon=0",
		"/v1/nearby?lat=0&lon=181",
		"/v1/nearby?lat=NaN&lon=0",
		"/v1/nearby?lat=Inf&lon=0",
		"/v1/nearby?lat=43&lon=-88&radius=0",
		"/v1/nearby?lat=43&lon=-88&radius=251",
		"/v1/nearby?lat=43&lon=-88&limit=0",
		"/v1/track/abc12",
		"/v1/track/abc1234",
		"/v1/track/abcxyz",
		"/v1/track/abc123?leg=-1",
		"/v1/aircraft/~abc123",
		"/v1/aircraft/ABC12G",
		"/v1/route/A",
		"/v1/route/ABCDEFGHI",
		"/v1/route/UAL-1",
		"/v1/route/UAL%201",
		"/v1/acars/%2E%2E",
		"/v1/acars/-N123",
		"/v1/acars/N12345678901",
		"/v1/metar",
		"/v1/metar?ids=KMK",
		"/v1/metar?ids=KMKE,K%2FRD",
		"/v1/metar?ids=" + strings.Repeat("KMKE,", 20) + "KORD,KMDW",
		"/v1/taf?ids=KMKEE",
		"/v1/history/sightings?since=abc",
		"/v1/history/sightings?limit=0",
		"/v1/history/sightings?after=zzzzzz",
		"/v1/history/legs?hex=nothex",
		"/v1/history/acars",
	}
	for _, target := range bad {
		if rec := h.do(t, "GET", target); rec.Code != 400 {
			t.Errorf("%s: got %d, want 400", target, rec.Code)
		}
	}
	if rec := h.do(t, "POST", "/v1/watch/xyz"); rec.Code != 400 {
		t.Errorf("watch bad hex: %d", rec.Code)
	}
	if n := h.up.countPrefix("/"); n != 0 {
		t.Fatalf("invalid input reached upstream %d times", n)
	}
}

func TestValidators(t *testing.T) {
	if h, ok := ValidHex("ABC123", false); !ok || h != "abc123" {
		t.Fatal("hex")
	}
	if _, ok := ValidHex("~abc123", false); ok {
		t.Fatal("~ allowed without allowNonICAO")
	}
	if h, ok := ValidHex("~ABC123", true); !ok || h != "~abc123" {
		t.Fatal("~hex")
	}
	if c, ok := ValidCallsign("ual1"); !ok || c != "UAL1" {
		t.Fatal("callsign case")
	}
	if c, ok := ValidICAO("kmke"); !ok || c != "KMKE" {
		t.Fatal("icao case")
	}
	if r, ok := ValidReg("n123ab"); !ok || r != "N123AB" {
		t.Fatal("reg")
	}
	if _, ok := ValidReg("G-EUPT"); !ok {
		t.Fatal("hyphenated reg")
	}
}

func TestNearbyFromAreaSnapshot(t *testing.T) {
	h := newHarness(t)
	h.poll.PollArea(context.Background())
	before := h.up.countPrefix("/fi/")
	rec := h.do(t, "GET", "/v1/nearby?lat=43.08&lon=-88.26&radius=25", "Accept-Encoding", "gzip")
	if rec.Code != 200 {
		t.Fatalf("%d %s", rec.Code, rec.Body)
	}
	resp := decode[NearbyResponse](t, rec)
	if resp.Source != "area" || resp.Feed != "adsb.fi" {
		t.Fatalf("source %q feed %q", resp.Source, resp.Feed)
	}
	// a00002 is ~31 nm north (outside 25 nm); a00003 is on the ground (excluded by default).
	if len(resp.Flights) != 1 || resp.Flights[0].ID != "a1cfb7" {
		t.Fatalf("flights %+v", resp.Flights)
	}
	f := resp.Flights[0]
	if f.Distance <= 0 || f.Distance > 3 || f.Callsign != "N2159Q" || f.Altitude != 1400 {
		t.Fatalf("flight %+v", f)
	}
	if h.up.countPrefix("/fi/") != before {
		t.Fatal("in-area request hit upstream")
	}
	withGround := decode[NearbyResponse](t, h.do(t, "GET", "/v1/nearby?lat=43.08&lon=-88.26&radius=25&ground=1"))
	if len(withGround.Flights) != 2 {
		t.Fatalf("ground=1: %d flights", len(withGround.Flights))
	}
}

func TestNearbyOutsideAreaCoalescedAndCached(t *testing.T) {
	h := newHarness(t)
	h.up.mu.Lock()
	h.up.delay = 50 * time.Millisecond
	h.up.mu.Unlock()
	var wg sync.WaitGroup
	codes := make([]int, 20)
	for i := range codes {
		wg.Add(1)
		go func() {
			defer wg.Done()
			codes[i] = h.do(t, "GET", "/v1/nearby?lat=51.47&lon=-0.45&radius=30").Code
		}()
	}
	wg.Wait()
	for _, c := range codes {
		if c != 200 {
			t.Fatalf("status %d", c)
		}
	}
	if n := h.up.countPrefix("/fi/v2/lat/"); n != 1 {
		t.Fatalf("%d upstream fetches for 20 concurrent requests, want 1", n)
	}
	if !strings.Contains(fmt.Sprint(h.up.hits), "/fi/v2/lat/51.47/lon/-0.45/dist/30") {
		t.Fatalf("position not rounded to 2 decimals upstream: %v", h.up.hits)
	}
	resp := decode[NearbyResponse](t, h.do(t, "GET", "/v1/nearby?lat=51.4712&lon=-0.4521&radius=30"))
	if resp.Source != "proxy" || resp.Cache != "hit" {
		t.Fatalf("source %s cache %s", resp.Source, resp.Cache)
	}
	if n := h.up.countPrefix("/fi/v2/lat/"); n != 1 {
		t.Fatal("cached request refetched")
	}
}

func TestRoutePersistedAcrossRestart(t *testing.T) {
	h := newHarness(t)
	rec := h.do(t, "GET", "/v1/route/ual1")
	if rec.Code != 200 || rec.Header().Get("X-Cache") != "miss" || !strings.Contains(rec.Body.String(), "United Airlines") {
		t.Fatalf("%d %s %s", rec.Code, rec.Header().Get("X-Cache"), rec.Body)
	}
	if rec := h.do(t, "GET", "/v1/route/UAL1"); rec.Header().Get("X-Cache") != "hit" {
		t.Fatal("second request not a hit")
	}
	// A new server on the same database (a restart) still has it.
	srv2 := New(Deps{Config: h.srv.cfg, Store: h.st, Client: h.srv.Client, Endpoints: h.srv.Endpoints, Feeds: h.srv.Feeds,
		Poller: h.poll, Tracker: h.tr})
	req := httptest.NewRequest("GET", "/v1/route/UAL1", nil)
	req.Header.Set("Authorization", "Bearer "+testToken)
	rec2 := httptest.NewRecorder()
	srv2.Handler().ServeHTTP(rec2, req)
	if rec2.Header().Get("X-Cache") != "hit" || h.up.count("/adsbdb/callsign/UAL1") != 1 {
		t.Fatalf("restart refetched: %s, %d upstream", rec2.Header().Get("X-Cache"), h.up.count("/adsbdb/callsign/UAL1"))
	}
	// Unknown callsigns are cached as 404 too.
	for range 2 {
		if rec := h.do(t, "GET", "/v1/route/UNKNOWN"); rec.Code != 404 {
			t.Fatalf("unknown: %d", rec.Code)
		}
	}
	if h.up.count("/adsbdb/callsign/UNKNOWN") != 1 {
		t.Fatal("negative answer not cached")
	}
	// The route was learned for leg metadata.
	if o, d, ok := h.srv.Routes.Lookup("UAL1"); !ok || o != "ORD" || d != "DEN" {
		t.Fatalf("route memo %s %s %v", o, d, ok)
	}
}

func TestAircraftLookup(t *testing.T) {
	h := newHarness(t)
	for range 3 {
		if rec := h.do(t, "GET", "/v1/aircraft/ABC123"); rec.Code != 200 {
			t.Fatalf("%d", rec.Code)
		}
	}
	if h.up.count("/adsbdb/aircraft/abc123") != 1 {
		t.Fatal("aircraft not cached")
	}
}

func TestWeatherPerStationCache(t *testing.T) {
	h := newHarness(t)
	recs := decode[[]map[string]any](t, h.do(t, "GET", "/v1/metar?ids=kmke,KORD,KNON"))
	if len(recs) != 2 {
		t.Fatalf("%d records", len(recs))
	}
	// KORD and KNON (no report) are cached; only KMDW is fetched.
	recs = decode[[]map[string]any](t, h.do(t, "GET", "/v1/metar?ids=KORD,KMDW,KNON"))
	if len(recs) != 2 || recs[0]["icaoId"] != "KORD" || recs[1]["icaoId"] != "KMDW" {
		t.Fatalf("records %v", recs)
	}
	if n := h.up.count("/wx/metar"); n != 2 {
		t.Fatalf("%d upstream requests, want 2", n)
	}
	if rec := h.do(t, "GET", "/v1/metar?ids=KORD"); rec.Header().Get("X-Cache") != "hit" {
		t.Fatal("not a hit")
	}
	// TAFs are cached separately.
	h.do(t, "GET", "/v1/taf?ids=KORD")
	if h.up.count("/wx/taf") != 1 {
		t.Fatal("taf")
	}
}

func TestAcarsProxyAndStorage(t *testing.T) {
	h := newHarness(t)
	rec := h.do(t, "GET", "/v1/acars/abc123")
	if rec.Code != 200 {
		t.Fatalf("%d %s", rec.Code, rec.Body)
	}
	resp := decode[AcarsResponse](t, rec)
	if resp.AirframeID == nil || *resp.AirframeID != 555 || resp.FlightID == nil || *resp.FlightID != 9001 {
		t.Fatalf("%+v", resp)
	}
	if !strings.Contains(string(resp.Flight), "hello") {
		t.Fatal("flight body missing")
	}
	h.do(t, "GET", "/v1/acars/abc123")
	if h.up.count("/af/flights/9001") != 1 || h.up.count("/af/airframes/icao/ABC123") != 1 {
		t.Fatalf("not cached: %v", h.up.hits)
	}
	hist := decode[map[string][]store.AcarsMessage](t, h.do(t, "GET", "/v1/history/acars?hex=abc123"))
	if len(hist["messages"]) != 2 || hist["messages"][0].Label != "H1" {
		t.Fatalf("stored %+v", hist)
	}
	// Unknown aircraft: both case variants are tried once, then the miss is cached.
	for range 2 {
		resp := decode[AcarsResponse](t, h.do(t, "GET", "/v1/acars/def456"))
		if resp.AirframeID != nil {
			t.Fatal("unknown aircraft has an id")
		}
	}
	if h.up.count("/af/airframes/icao/DEF456") != 1 || h.up.count("/af/airframes/icao/def456") != 1 {
		t.Fatalf("miss not cached: %v", h.up.hits)
	}
}

func TestTrackMergesServerHistoryWithOpenSkyOncePerLeg(t *testing.T) {
	h := newHarness(t)
	ctx := context.Background()
	now := time.Now()
	// The server picked the flight up in cruise 20 minutes ago (it missed the departure).
	for i := range 20 {
		ts := now.Add(-20*time.Minute + time.Duration(i)*time.Minute)
		tr := 45.0
		f := adsb.Flight{ID: "abc123", Callsign: "UAL1", Altitude: 30000, Speed: 450, Track: &tr,
			Lat: 42.6 + float64(i)*0.05, Lon: -87.4 + float64(i)*0.05, PositionTime: float64(ts.Unix())}
		h.tr.Observe(ctx, []adsb.Flight{f}, store.SourceArea)
	}
	if err := h.tr.Flush(ctx, now); err != nil {
		t.Fatal(err)
	}
	resp := decode[TrackResponse](t, h.do(t, "GET", "/v1/track/abc123"))
	if resp.Source != "merged" || !resp.Active || resp.Leg == nil || resp.Callsign != "UAL1" {
		t.Fatalf("source %s active %v leg %+v", resp.Source, resp.Active, resp.Leg)
	}
	first := resp.Path[0]
	if first[5] != true || first[3].(float64) != 0 {
		t.Fatalf("track should start on the ground from OpenSky with altitude 0: %v", first)
	}
	// OpenSky's two points before the server's first point, then the server's 20.
	if len(resp.Path) != 2+20 {
		t.Fatalf("%d points", len(resp.Path))
	}
	// Again: OpenSky's track is stored per leg; no second request.
	decode[TrackResponse](t, h.do(t, "GET", "/v1/track/abc123"))
	if n := h.up.countPrefix("/opensky/"); n != 1 {
		t.Fatalf("%d OpenSky requests, want 1", n)
	}
	// opensky=0 returns only the server's own history.
	own := decode[TrackResponse](t, h.do(t, "GET", "/v1/track/abc123?opensky=0"))
	if own.Source != "server" {
		t.Fatalf("opensky=0 source %s", own.Source)
	}
	// Unknown aircraft without history: OpenSky only.
	other := decode[TrackResponse](t, h.do(t, "GET", "/v1/track/fff000"))
	if other.Source != "opensky" {
		t.Fatalf("source %s", other.Source)
	}
}

func TestTrackWithFullCoverageSkipsOpenSky(t *testing.T) {
	h := newHarness(t)
	ctx := context.Background()
	now := time.Now()
	pts := trackenc.Simulate(trackenc.Departure, now.Add(-40*time.Minute).Unix(), 43, -88, 1)
	for _, p := range pts {
		if p.T > now.Unix() {
			break
		}
		tr := float64(p.Track)
		h.tr.Observe(ctx, []adsb.Flight{{ID: "abc123", Altitude: p.AltFt, OnGround: p.Ground, Speed: float64(p.SpeedKt), Track: &tr,
			Lat: p.Lat, Lon: p.Lon, PositionTime: float64(p.T)}}, store.SourceArea)
	}
	resp := decode[TrackResponse](t, h.do(t, "GET", "/v1/track/abc123"))
	if resp.Source != "server" || h.up.countPrefix("/opensky/") != 0 {
		t.Fatalf("source %s, %d OpenSky requests", resp.Source, h.up.countPrefix("/opensky/"))
	}
}

func TestWatchEndpoints(t *testing.T) {
	h := newHarness(t)
	for _, hex := range []string{"400001", "400002"} {
		if rec := h.do(t, "POST", "/v1/watch/"+hex); rec.Code != 202 {
			t.Fatalf("%d", rec.Code)
		}
	}
	if rec := h.do(t, "POST", "/v1/watch/400003"); rec.Code != 429 {
		t.Fatalf("cap: %d", rec.Code)
	}
	if rec := h.do(t, "DELETE", "/v1/watch/400001"); rec.Code != 204 {
		t.Fatalf("delete: %d", rec.Code)
	}
	if rec := h.do(t, "DELETE", "/v1/watch/400001"); rec.Code != 404 {
		t.Fatalf("delete again: %d", rec.Code)
	}
	list := decode[map[string]any](t, h.do(t, "GET", "/v1/watch"))
	if list["active"].(float64) != 1 {
		t.Fatalf("%v", list)
	}
}

func TestSightingsAndStats(t *testing.T) {
	h := newHarness(t)
	h.poll.PollArea(context.Background())
	if err := h.tr.Flush(context.Background(), time.Now()); err != nil {
		t.Fatal(err)
	}
	resp := decode[SightingsResponse](t, h.do(t, "GET", "/v1/history/sightings?since=0&limit=2"))
	if len(resp.Sightings) != 2 || resp.Next == nil {
		t.Fatalf("page 1: %d next %v", len(resp.Sightings), resp.Next)
	}
	page2 := decode[SightingsResponse](t, h.do(t, "GET", fmt.Sprintf("/v1/history/sightings?since=%d&after=%s&limit=2", resp.Next.Since, resp.Next.After)))
	if len(page2.Sightings) != 1 || page2.Next != nil {
		t.Fatalf("page 2: %d", len(page2.Sightings))
	}
	stats := decode[map[string]any](t, h.do(t, "GET", "/v1/stats"))
	for _, k := range []string{"db", "upstream", "poller", "watches", "tracker", "memory"} {
		if _, ok := stats[k]; !ok {
			t.Errorf("stats missing %q", k)
		}
	}
	up := stats["upstream"].(map[string]any)["services"].(map[string]any)["adsb.fi"].(map[string]any)
	if up["requests"].(float64) != 1 {
		t.Fatalf("adsb.fi count %v", up)
	}
	legs := decode[map[string][]store.Leg](t, h.do(t, "GET", "/v1/history/legs?hex=a1cfb7"))
	if len(legs["legs"]) != 1 {
		t.Fatalf("legs %v", legs)
	}
}

func TestGzipAndHeaders(t *testing.T) {
	h := newHarness(t)
	h.poll.PollArea(context.Background())
	rec := h.do(t, "GET", "/v1/nearby?lat=43.08&lon=-88.26&radius=50&ground=1", "Accept-Encoding", "gzip")
	if rec.Body.Len() >= gzipMin && rec.Header().Get("Content-Encoding") != "gzip" {
		t.Fatal("large response not gzipped")
	}
	if rec.Header().Get("X-Content-Type-Options") != "nosniff" || rec.Header().Get("Cache-Control") != "no-store" {
		t.Fatal("security headers missing")
	}
	if acceptsGzip(&http.Request{Header: http.Header{"Accept-Encoding": {"gzip;q=0"}}}) {
		t.Fatal("q=0 honoured as accept")
	}
	if !acceptsGzip(&http.Request{Header: http.Header{"Accept-Encoding": {"br, gzip;q=0.5"}}}) {
		t.Fatal("q=0.5 rejected")
	}
}

func TestUpstreamPausedGives503(t *testing.T) {
	h := newHarness(t)
	// Exhaust OpenSky's budget, then ask for a track for an unknown aircraft: no request is made
	// and the API still answers (404: nothing known), never hammering the upstream.
	day, _ := h.srv.Client.Counts()
	h.srv.Client.Restore(day, map[string]int{"opensky": 400})
	if rec := h.do(t, "GET", "/v1/track/fff001"); rec.Code != 404 {
		t.Fatalf("%d", rec.Code)
	}
	if h.up.countPrefix("/opensky/") != 0 {
		t.Fatal("OpenSky used beyond budget")
	}
}
