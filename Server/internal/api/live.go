package api

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"math"
	"net/http"
	"slices"
	"strconv"
	"time"

	"github.com/BadWasabeee/flightdesk/Server/internal/adsb"
	"github.com/BadWasabeee/flightdesk/Server/internal/cache"
	"github.com/BadWasabeee/flightdesk/Server/internal/geo"
	"github.com/BadWasabeee/flightdesk/Server/internal/poller"
	"github.com/BadWasabeee/flightdesk/Server/internal/store"
	"github.com/BadWasabeee/flightdesk/Server/internal/trackenc"
	"github.com/BadWasabeee/flightdesk/Server/internal/upstream"
)

// ---- /v1/nearby ----

// NearbyResponse is the /v1/nearby body.
type NearbyResponse struct {
	Source  string        `json:"source"`  // "area" (server snapshot) or "proxy" (one upstream fetch)
	Feed    string        `json:"feed"`    // "adsb.fi" or "adsb.lol"
	Time    float64       `json:"time"`    // Unix seconds of the feed data
	Age     float64       `json:"age"`     // seconds since Time
	Cache   string        `json:"cache"`   // proxy only: hit | miss | stale
	Flights []adsb.Flight `json:"flights"` // nearest first
}

type proxiedNearby struct {
	Time    float64       `json:"t"`
	Feed    string        `json:"s"`
	Flights []adsb.Flight `json:"f"`
}

const nearbyTTL = 5 * time.Second

func (s *Server) handleNearby(w http.ResponseWriter, r *http.Request) {
	q := r.URL.Query()
	lat, ok1 := ValidLat(q.Get("lat"))
	lon, ok2 := ValidLon(q.Get("lon"))
	radius := 25.0
	ok3 := true
	if v := q.Get("radius"); v != "" {
		radius, ok3 = ValidRadius(v)
	}
	limit, ok4 := parseInt(q.Get("limit"), 2000, 1, 2000)
	ground := q.Get("ground") == "1" || q.Get("ground") == "true"
	if !ok1 || !ok2 || !ok3 || !ok4 {
		writeError(w, r, http.StatusBadRequest, "lat (-90..90), lon (-180..180) required; radius 1..250 nm; limit 1..2000")
		return
	}
	now := s.now()
	var resp NearbyResponse
	var flights []adsb.Flight
	pc := s.Poller.Config()
	snap := s.Poller.Snapshot()
	fresh := snap != nil && now.Sub(snap.Time) < max(3*pc.Interval, 30*time.Second)
	if fresh && pc.RadiusNM > 0 && geo.CircleInside(lat, lon, radius, pc.CenterLat, pc.CenterLon, float64(pc.RadiusNM)) {
		resp = NearbyResponse{Source: "area", Feed: string(snap.Source), Time: unixF(snap.Time)}
		flights = snap.Flights
	} else {
		// Outside the area (or the poller is down): one upstream fetch per ~1 km cell and whole
		// radius, cached briefly and shared by concurrent callers.
		latR, lonR := math.Round(lat*100)/100, math.Round(lon*100)/100
		nm := int(math.Ceil(radius))
		key := fmt.Sprintf("%.2f,%.2f,%d", latR, lonR, nm)
		v, res, err := s.nearby.Get(r.Context(), key, func(ctx context.Context) (cache.Value, time.Duration, error) {
			ar, feed, err := s.Feeds.Point(ctx, latR, lonR, nm, 2)
			if err != nil {
				return cache.Value{}, 0, err
			}
			fetched := s.now()
			body, err := json.Marshal(proxiedNearby{Time: unixF(ar.Time(fetched)), Feed: string(feed), Flights: adsb.Flights(ar, fetched)})
			return cache.Value{Status: 200, Body: body}, nearbyTTL, err
		})
		if err != nil {
			s.upstreamError(w, r, err)
			return
		}
		var p proxiedNearby
		if err := json.Unmarshal(v.Body, &p); err != nil {
			writeError(w, r, http.StatusInternalServerError, "cache decode failed")
			return
		}
		resp = NearbyResponse{Source: "proxy", Feed: p.Feed, Time: p.Time, Cache: res.String()}
		flights = p.Flights
	}
	out := make([]adsb.Flight, 0, min(len(flights), 256))
	for _, f := range flights {
		if f.OnGround && !ground {
			continue // the apps' Flight(adsb:) skips ground traffic; ?ground=1 includes it
		}
		if f = f.Locate(lat, lon); f.Distance <= radius {
			out = append(out, f)
		}
	}
	slices.SortFunc(out, func(a, b adsb.Flight) int {
		if a.Distance != b.Distance {
			if a.Distance < b.Distance {
				return -1
			}
			return 1
		}
		if a.ID < b.ID {
			return -1
		}
		return 1
	})
	if int64(len(out)) > limit {
		out = out[:limit]
	}
	resp.Flights = out
	resp.Age = math.Round((unixF(now)-resp.Time)*10) / 10
	writeJSON(w, r, http.StatusOK, resp)
}

func unixF(t time.Time) float64 { return math.Round(float64(t.UnixMilli())) / 1000 }

// upstreamError maps upstream failures to responses.
func (s *Server) upstreamError(w http.ResponseWriter, r *http.Request, err error) {
	switch {
	case errors.Is(err, upstream.ErrPaused), errors.Is(err, upstream.ErrBudget), errors.Is(err, upstream.ErrBusy), errors.Is(err, poller.ErrNoFeed):
		retryAfter(w, 60*time.Second)
		writeError(w, r, http.StatusServiceUnavailable, "upstream rate limit: try again later")
	case errors.Is(err, context.Canceled):
		writeError(w, r, 499, "client closed request")
	default:
		s.log.Warn("upstream request failed", "path", r.URL.Path, "err", err)
		writeError(w, r, http.StatusBadGateway, "upstream unavailable")
	}
}

// ---- /v1/track/{hex} ----

// TrackResponse mirrors OpenSky's /tracks/all body (so the apps' FlightTrack(data:) parser reads
// it unchanged) plus server fields. path entries are
// [time (Unix s), lat, lon, baro altitude (metres) | null, true track (deg) | null, on ground].
type TrackResponse struct {
	ICAO24    string     `json:"icao24"`
	Callsign  string     `json:"callsign"`
	StartTime int64      `json:"startTime"`
	EndTime   int64      `json:"endTime"`
	Path      [][]any    `json:"path"`
	Source    string     `json:"source"` // server | opensky | merged
	Active    bool       `json:"active"` // the server is following this leg now
	Leg       *store.Leg `json:"leg,omitempty"`
}

// openSkyTrack is OpenSky's /tracks/all body.
type openSkyTrack struct {
	ICAO24    string  `json:"icao24"`
	Callsign  string  `json:"callsign"`
	StartTime float64 `json:"startTime"`
	EndTime   float64 `json:"endTime"`
	Path      [][]any `json:"path"`
}

func parseOpenSky(body []byte) ([]trackenc.Point, error) {
	var t openSkyTrack
	if err := json.Unmarshal(body, &t); err != nil {
		return nil, err
	}
	num := func(v any) (float64, bool) {
		f, ok := v.(float64)
		return f, ok && !math.IsNaN(f) && !math.IsInf(f, 0)
	}
	var out []trackenc.Point
	for _, w := range t.Path {
		if len(w) < 3 {
			continue
		}
		ts, ok1 := num(w[0])
		lat, ok2 := num(w[1])
		lon, ok3 := num(w[2])
		if !ok1 || !ok2 || !ok3 || math.Abs(lat) > 90 || math.Abs(lon) > 180 {
			continue
		}
		p := trackenc.Point{T: int64(ts), Lat: lat, Lon: lon, Track: trackenc.TrackUnknown}
		if len(w) > 3 {
			if m, ok := num(w[3]); ok {
				p.AltFt = int(math.Round(m * 3.28084))
			}
		}
		if len(w) > 4 {
			if tr, ok := num(w[4]); ok {
				p.Track = int(math.Round(math.Mod(tr+360, 360))) % 360
			}
		}
		if len(w) > 5 {
			p.Ground, _ = w[5].(bool)
		}
		if len(out) > 0 && p.T < out[len(out)-1].T {
			continue
		}
		out = append(out, p)
	}
	return out, nil
}

// lacksDeparture: the server's track starts in the air (above 3,000 ft), so it missed the
// departure and OpenSky may fill the gap.
func lacksDeparture(pts []trackenc.Point) bool {
	return len(pts) == 0 || (!pts[0].Ground && pts[0].AltFt > 3000)
}

func (s *Server) handleTrack(w http.ResponseWriter, r *http.Request) {
	hex, ok := ValidHex(r.PathValue("hex"), true)
	legID, okLeg := parseInt(r.URL.Query().Get("leg"), 0, 0, math.MaxInt64)
	if !ok || !okLeg {
		writeError(w, r, http.StatusBadRequest, "hex must be 6 hex digits (optionally ~-prefixed); leg must be an integer id")
		return
	}
	useOpenSky := r.URL.Query().Get("opensky") != "0"
	ctx := r.Context()
	now := s.now()

	var leg *store.Leg
	var pts []trackenc.Point
	active := false
	switch {
	case legID > 0:
		l, err := s.Store.Leg(ctx, legID)
		if err != nil {
			writeError(w, r, http.StatusInternalServerError, "database error")
			return
		}
		if l == nil || l.Hex != hex {
			writeError(w, r, http.StatusNotFound, "no such leg for this aircraft")
			return
		}
		leg = l
		if pts, err = s.Store.Track(ctx, l); err != nil {
			writeError(w, r, http.StatusInternalServerError, "track decode failed")
			return
		}
		useOpenSky = false
	default:
		t, isActive, err := s.Tracker.ActiveTrack(ctx, hex)
		if err != nil {
			writeError(w, r, http.StatusInternalServerError, "track read failed")
			return
		}
		if isActive {
			leg, pts, active = &t.Leg, t.Points, true
		} else if l, err := s.Store.LatestLeg(ctx, hex, now.Add(-20*time.Hour).Unix()); err == nil && l != nil {
			leg = l
			pts, _ = s.Store.Track(ctx, l)
		}
	}

	var osPts []trackenc.Point
	// OpenSky only knows the current/most recent flight, and is budgeted (~400/day): ask only
	// when the server lacks the departure of a recent leg, and at most once per leg.
	recent := leg == nil || now.Unix()-leg.LastSeen < 30*60
	if useOpenSky && recent && hex[0] != '~' && lacksDeparture(pts) {
		osPts = s.openSkyFor(ctx, hex, leg)
	}
	if leg != nil && len(osPts) > 0 && osPts[len(osPts)-1].T < leg.FirstSeen-600 {
		osPts = nil // OpenSky's track is an earlier flight
	}

	merged, source := mergeTracks(pts, osPts)
	if len(merged) == 0 {
		writeError(w, r, http.StatusNotFound, "no track for this aircraft")
		return
	}
	resp := TrackResponse{ICAO24: hex, StartTime: merged[0].T, EndTime: merged[len(merged)-1].T, Source: source, Active: active, Leg: leg}
	if leg != nil {
		resp.Callsign = leg.Callsign
	}
	resp.Path = make([][]any, len(merged))
	for i, p := range merged {
		// Altitude is always present (0 on the ground): the apps' RouteResolver.departure needs
		// the first point's altitude to recognise a departure.
		alt := math.Round(float64(p.AltFt)*0.3048*10) / 10
		var track any
		if p.HasTrack() {
			track = p.Track
		}
		resp.Path[i] = []any{p.T, p.Lat, p.Lon, alt, track, p.Ground}
	}
	writeJSON(w, r, http.StatusOK, resp)
}

// mergeTracks prepends OpenSky points from before the server's first point.
func mergeTracks(server, os []trackenc.Point) ([]trackenc.Point, string) {
	switch {
	case len(os) == 0:
		return server, "server"
	case len(server) == 0:
		return os, "opensky"
	}
	cut := server[0].T - 30
	var out []trackenc.Point
	for _, p := range os {
		if p.T < cut {
			out = append(out, p)
		}
	}
	if len(out) == 0 {
		return server, "server"
	}
	return append(out, server...), "merged"
}

// openSkyFor returns OpenSky's track for the aircraft's current leg: stored per leg in the
// database (one request per leg, ever), or for an aircraft the server doesn't know, cached in
// memory by hex for 10 minutes.
func (s *Server) openSkyFor(ctx context.Context, hex string, leg *store.Leg) []trackenc.Point {
	if leg != nil && leg.ID != 0 {
		if t, err := s.Store.OpenSky(ctx, leg.ID); err == nil && t != nil {
			return t.Points
		}
	}
	key := "opensky:" + hex
	if leg != nil {
		key += ":" + strconv.FormatInt(leg.ID, 10)
	}
	v, _, err := s.live.Get(ctx, key, func(ctx context.Context) (cache.Value, time.Duration, error) {
		if !s.Client.Available(upstream.OpenSky) {
			return cache.Value{}, 0, upstream.ErrBudget
		}
		resp, err := s.Client.Get(ctx, upstream.OpenSky, s.Endpoints.OpenSky+"/tracks/all?icao24="+hex+"&time=0")
		if err != nil {
			return cache.Value{}, 0, err
		}
		// 404 = OpenSky has no track: remember that for a while too, so we don't ask again.
		if resp.Status != 200 && resp.Status != 404 {
			return cache.Value{}, 0, fmt.Errorf("opensky: HTTP %d", resp.Status)
		}
		return cache.Value{Status: resp.Status, Body: resp.Body}, 10 * time.Minute, nil
	})
	if err != nil || v.Status != 200 {
		return nil
	}
	pts, err := parseOpenSky(v.Body)
	if err != nil || len(pts) < 2 {
		return nil
	}
	if leg != nil && leg.ID != 0 && pts[len(pts)-1].T >= leg.FirstSeen-600 {
		if err := s.Store.PutOpenSky(ctx, leg.ID, s.now().Unix(), pts); err != nil {
			s.log.Warn("storing OpenSky track failed", "err", err)
		}
	}
	return pts
}

// ---- /v1/watch ----

type watchResponse struct {
	Watch  poller.Watch `json:"watch"`
	Active int          `json:"active"`
	Max    int          `json:"max"`
}

func (s *Server) handleWatchAdd(w http.ResponseWriter, r *http.Request) {
	hex, ok := ValidHex(r.PathValue("hex"), false)
	if !ok {
		writeError(w, r, http.StatusBadRequest, "hex must be 6 hex digits")
		return
	}
	wt, n, err := s.Poller.AddWatch(r.Context(), hex)
	if errors.Is(err, poller.ErrWatchLimit) {
		retryAfter(w, 5*time.Minute)
		writeError(w, r, http.StatusTooManyRequests, fmt.Sprintf("watch limit reached (%d active)", n))
		return
	}
	writeJSON(w, r, http.StatusAccepted, watchResponse{Watch: wt, Active: n, Max: s.Poller.MaxWatches()})
}

func (s *Server) handleWatchRemove(w http.ResponseWriter, r *http.Request) {
	hex, ok := ValidHex(r.PathValue("hex"), false)
	if !ok {
		writeError(w, r, http.StatusBadRequest, "hex must be 6 hex digits")
		return
	}
	if !s.Poller.RemoveWatch(r.Context(), hex) {
		writeError(w, r, http.StatusNotFound, "not watching this aircraft")
		return
	}
	w.WriteHeader(http.StatusNoContent)
}

func (s *Server) handleWatchList(w http.ResponseWriter, r *http.Request) {
	list := s.Poller.Watches()
	writeJSON(w, r, http.StatusOK, map[string]any{"watches": list, "active": len(list), "max": s.Poller.MaxWatches()})
}
