package api

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"net/http"
	"net/url"
	"strconv"
	"strings"
	"sync"
	"time"

	"github.com/BadWasabeee/flightdesk/Server/internal/cache"
	"github.com/BadWasabeee/flightdesk/Server/internal/store"
	"github.com/BadWasabeee/flightdesk/Server/internal/upstream"
)

// ---- persisted lookups (adsbdb, Airframes ids) ----

type lookupResult struct {
	Status int
	Body   []byte
	Cache  string // hit | miss | stale
}

// persistedLookup serves kind/key from the database while fresh; otherwise fetches it once (shared
// by concurrent callers), stores definitive answers (200 or 404) with ttlHit/ttlMiss, and falls
// back to a stale stored answer when the upstream fails.
func (s *Server) persistedLookup(ctx context.Context, kind, key string, ttlHit, ttlMiss time.Duration,
	fetch func(ctx context.Context) (status int, body []byte, err error)) (lookupResult, error) {
	now := s.now()
	stored, err := s.Store.GetLookup(ctx, kind, key)
	if err != nil {
		return lookupResult{}, err
	}
	if stored != nil && now.Unix() < stored.ExpiresAt {
		return lookupResult{Status: stored.Status, Body: stored.Body, Cache: "hit"}, nil
	}
	v, _, err := s.lookups.Get(ctx, kind+":"+key, func(ctx context.Context) (cache.Value, time.Duration, error) {
		status, body, err := fetch(ctx)
		if err != nil {
			return cache.Value{}, 0, err
		}
		if status != 200 && status != 404 {
			return cache.Value{}, 0, fmt.Errorf("%s: HTTP %d", kind, status)
		}
		ttl := ttlHit
		if status == 404 {
			ttl = ttlMiss
		}
		t := s.now()
		if err := s.Store.PutLookup(ctx, kind, key, store.Lookup{Status: status, Body: body, FetchedAt: t.Unix(), ExpiresAt: t.Add(ttl).Unix()}); err != nil {
			s.log.Warn("storing lookup failed", "kind", kind, "err", err)
		}
		// Coalesce only: the database is the cache.
		return cache.Value{Status: status, Body: body}, time.Second, nil
	})
	if err != nil {
		if stored != nil {
			return lookupResult{Status: stored.Status, Body: stored.Body, Cache: "stale"}, nil
		}
		return lookupResult{}, err
	}
	return lookupResult{Status: v.Status, Body: v.Body, Cache: "miss"}, nil
}

func (s *Server) writeLookup(w http.ResponseWriter, r *http.Request, res lookupResult, err error) {
	if err != nil {
		s.upstreamError(w, r, err)
		return
	}
	w.Header().Set("X-Cache", res.Cache)
	writeRawJSON(w, r, res.Status, res.Body)
}

func (s *Server) upstreamGet(svc upstream.Service, u string) func(ctx context.Context) (int, []byte, error) {
	return func(ctx context.Context) (int, []byte, error) {
		resp, err := s.Client.Get(ctx, svc, u)
		if err != nil {
			return 0, nil, err
		}
		return resp.Status, resp.Body, nil
	}
}

// ---- /v1/route/{callsign}, /v1/aircraft/{hex} (adsbdb) ----

const (
	routeTTL       = 24 * time.Hour
	routeMissTTL   = 6 * time.Hour
	aircraftTTL    = 30 * 24 * time.Hour
	aircraftMissTT = 7 * 24 * time.Hour
)

func (s *Server) handleRoute(w http.ResponseWriter, r *http.Request) {
	cs, ok := ValidCallsign(r.PathValue("callsign"))
	if !ok {
		writeError(w, r, http.StatusBadRequest, "callsign must match [A-Z0-9]{2,8}")
		return
	}
	res, err := s.persistedLookup(r.Context(), "route", cs, routeTTL, routeMissTTL,
		s.upstreamGet(upstream.Adsbdb, s.Endpoints.Adsbdb+"/callsign/"+cs))
	if err == nil && res.Status == 200 {
		s.learnRoute(r.Context(), cs, res.Body)
	}
	s.writeLookup(w, r, res, err)
}

func (s *Server) handleAircraft(w http.ResponseWriter, r *http.Request) {
	hex, ok := ValidHex(r.PathValue("hex"), false)
	if !ok {
		writeError(w, r, http.StatusBadRequest, "hex must be 6 hex digits")
		return
	}
	res, err := s.persistedLookup(r.Context(), "aircraft", hex, aircraftTTL, aircraftMissTT,
		s.upstreamGet(upstream.Adsbdb, s.Endpoints.Adsbdb+"/aircraft/"+hex))
	s.writeLookup(w, r, res, err)
}

// adsbdbRoute is the part of adsbdb's /callsign response used for leg metadata.
type adsbdbRoute struct {
	Response struct {
		FlightRoute *struct {
			Origin      adsbdbAirport `json:"origin"`
			Destination adsbdbAirport `json:"destination"`
		} `json:"flightroute"`
	} `json:"response"`
}

type adsbdbAirport struct {
	IATA string `json:"iata_code"`
	ICAO string `json:"icao_code"`
}

// code matches the apps' Airport.code: IATA when known, else ICAO.
func (a adsbdbAirport) code() string {
	if a.IATA != "" {
		return a.IATA
	}
	return a.ICAO
}

// learnRoute records a fetched route for leg metadata and the sightings log.
func (s *Server) learnRoute(ctx context.Context, callsign string, body []byte) {
	var rt adsbdbRoute
	if json.Unmarshal(body, &rt) != nil || rt.Response.FlightRoute == nil {
		return
	}
	o, d := rt.Response.FlightRoute.Origin.code(), rt.Response.FlightRoute.Destination.code()
	if o == "" || d == "" {
		return
	}
	if s.Routes.Put(callsign, o, d, s.now()) {
		if err := s.Store.SetRoute(ctx, callsign, o, d, s.now().Add(-20*time.Hour).Unix()); err != nil {
			s.log.Warn("setting leg route failed", "err", err)
		}
	}
}

// RouteMemo remembers recently fetched routes in memory, so the tracker can label legs and
// sightings without a database query (or an upstream request) per aircraft per poll.
type RouteMemo struct {
	mu  sync.Mutex
	max int
	m   map[string]routeMemoEntry
}

type routeMemoEntry struct {
	origin, dest string
	at           time.Time
}

// NewRouteMemo holds at most max routes.
func NewRouteMemo(max int) *RouteMemo { return &RouteMemo{max: max, m: map[string]routeMemoEntry{}} }

// Put stores a route and reports whether it was new or changed.
func (m *RouteMemo) Put(callsign, origin, dest string, now time.Time) bool {
	m.mu.Lock()
	defer m.mu.Unlock()
	old, ok := m.m[callsign]
	if len(m.m) >= m.max && !ok {
		for k, e := range m.m {
			if now.Sub(e.at) > routeTTL {
				delete(m.m, k)
			}
		}
		if len(m.m) >= m.max {
			for k := range m.m { // still full: drop an arbitrary entry
				delete(m.m, k)
				break
			}
		}
	}
	m.m[callsign] = routeMemoEntry{origin, dest, now}
	return !ok || old.origin != origin || old.dest != dest
}

// Lookup is a tracker.RouteFunc.
func (m *RouteMemo) Lookup(callsign string) (string, string, bool) {
	m.mu.Lock()
	defer m.mu.Unlock()
	e, ok := m.m[callsign]
	if !ok || time.Since(e.at) > routeTTL {
		return "", "", false
	}
	return e.origin, e.dest, true
}

// ---- /v1/acars/{hex-or-reg} (Airframes.io) ----

// AcarsResponse is the /v1/acars body: Airframes' own JSON for the airframe (with its flight
// list) and for one flight (with its latest messages), so the apps' AirframesAPI decoders read
// them unchanged.
type AcarsResponse struct {
	AirframeID *int64          `json:"airframeId"`
	Airframe   json.RawMessage `json:"airframe"`
	FlightID   *int64          `json:"flightId"`
	Flight     json.RawMessage `json:"flight"`
}

const (
	airframeIDTTL     = 24 * time.Hour // as AcarsService.hitLifetime
	airframeIDMissTTL = 6 * time.Hour  // as AcarsService.missLifetime
	airframeTTL       = 115 * time.Second
	acarsFlightTTL    = 100 * time.Second
	currentFlightAge  = 18 * time.Hour // as AcarsFlightMatcher.maxAge
)

type flexID int64

func (f *flexID) UnmarshalJSON(b []byte) error {
	s := strings.Trim(string(b), `"`)
	n, err := strconv.ParseInt(s, 10, 64)
	if err != nil {
		return err
	}
	*f = flexID(n)
	return nil
}

func isBlank(b []byte) bool { return len(strings.TrimSpace(string(b))) == 0 }

func (s *Server) handleAcars(w http.ResponseWriter, r *http.Request) {
	raw := r.PathValue("id")
	hex, isHex := ValidHex(raw, false)
	reg, isReg := ValidReg(raw)
	flightParam, okF := parseInt(r.URL.Query().Get("flight"), 0, 0, 1<<53)
	if (!isHex && !isReg) || !okF {
		writeError(w, r, http.StatusBadRequest, "id must be a 6-digit hex or a registration ([A-Z0-9-]{2,10}); flight must be an integer")
		return
	}
	ctx := r.Context()
	base := s.Endpoints.Airframes

	// 1. Airframes' id for the aircraft (persisted for a day; misses for 6 hours).
	kindKey := "hex:" + hex
	if !isHex {
		kindKey = "tail:" + reg
	}
	idRes, err := s.persistedLookup(ctx, "airframe-id", kindKey, airframeIDTTL, airframeIDMissTTL, func(ctx context.Context) (int, []byte, error) {
		var variants []string
		if isHex {
			// Airframes stores most addresses uppercase, some lowercase, and matches exactly.
			variants = []string{base + "/airframes/icao/" + strings.ToUpper(hex), base + "/airframes/icao/" + hex}
		} else {
			variants = []string{base + "/airframes/tail/" + url.PathEscape(reg)}
		}
		for _, u := range variants {
			resp, err := s.Client.Get(ctx, upstream.Airframes, u)
			if err != nil {
				return 0, nil, err
			}
			if resp.Status == 404 || (resp.Status == 200 && isBlank(resp.Body)) {
				continue
			}
			if resp.Status != 200 {
				return resp.Status, nil, nil
			}
			var a struct {
				ID flexID `json:"id"`
			}
			if json.Unmarshal(resp.Body, &a) != nil || a.ID <= 0 {
				continue
			}
			return 200, []byte(strconv.FormatInt(int64(a.ID), 10)), nil
		}
		return 404, []byte{}, nil
	})
	if err != nil {
		s.upstreamError(w, r, err)
		return
	}
	out := AcarsResponse{Airframe: json.RawMessage("null"), Flight: json.RawMessage("null")}
	if idRes.Status != 200 {
		writeJSON(w, r, http.StatusOK, out) // Airframes has never heard of this aircraft
		return
	}
	airframeID, _ := strconv.ParseInt(string(idRes.Body), 10, 64)
	out.AirframeID = &airframeID

	// 2. The airframe with its flight list (shared for ~2 minutes).
	af, _, err := s.live.Get(ctx, "af:"+strconv.FormatInt(airframeID, 10), s.liveFetch(upstream.Airframes,
		base+"/airframes/"+strconv.FormatInt(airframeID, 10), airframeTTL))
	if err != nil {
		s.upstreamError(w, r, err)
		return
	}
	if !isBlank(af.Body) && json.Valid(af.Body) {
		out.Airframe = af.Body
	}
	var afDoc struct {
		ICAO    string `json:"icao"`
		Flights []struct {
			ID        flexID    `json:"id"`
			UpdatedAt time.Time `json:"updatedAt"`
		} `json:"flights"`
	}
	_ = json.Unmarshal(af.Body, &afDoc)
	if !isHex {
		hex, _ = ValidHex(afDoc.ICAO, false)
	}

	// 3. The flight: the one asked for (it must belong to this airframe), else the most recently
	// updated within 18 hours. Clients wanting the apps' exact matching can pass ?flight=.
	var flightID int64
	var newest time.Time
	for _, f := range afDoc.Flights {
		switch {
		case flightParam > 0:
			if int64(f.ID) == flightParam {
				flightID = flightParam
			}
		case s.now().Sub(f.UpdatedAt) < currentFlightAge && f.UpdatedAt.After(newest):
			flightID, newest = int64(f.ID), f.UpdatedAt
		}
	}
	if flightID == 0 {
		writeJSON(w, r, http.StatusOK, out)
		return
	}
	out.FlightID = &flightID
	fl, res, err := s.live.Get(ctx, "afl:"+strconv.FormatInt(flightID, 10), s.liveFetch(upstream.Airframes,
		base+"/flights/"+strconv.FormatInt(flightID, 10), acarsFlightTTL))
	if err != nil {
		s.upstreamError(w, r, err)
		return
	}
	if !isBlank(fl.Body) && json.Valid(fl.Body) {
		out.Flight = fl.Body
		if res == cache.Fetched && hex != "" {
			s.storeAcars(ctx, hex, flightID, fl.Body)
		}
	}
	writeJSON(w, r, http.StatusOK, out)
}

// liveFetch is a cache.FetchFunc for a short-lived upstream JSON document (200 only).
func (s *Server) liveFetch(svc upstream.Service, u string, ttl time.Duration) cache.FetchFunc {
	return func(ctx context.Context) (cache.Value, time.Duration, error) {
		resp, err := s.Client.Get(ctx, svc, u)
		if err != nil {
			return cache.Value{}, 0, err
		}
		if resp.Status == 404 {
			return cache.Value{Status: 404}, ttl, nil
		}
		if resp.Status != 200 {
			return cache.Value{}, 0, fmt.Errorf("%s: HTTP %d", svc, resp.Status)
		}
		return cache.Value{Status: 200, Body: resp.Body}, ttl, nil
	}
}

// storeAcars keeps the messages of a fetched flight.
func (s *Server) storeAcars(ctx context.Context, hex string, flightID int64, body []byte) {
	var doc struct {
		Messages []json.RawMessage `json:"messages"`
	}
	if json.Unmarshal(body, &doc) != nil {
		return
	}
	msgs := make([]store.AcarsMessage, 0, len(doc.Messages))
	for _, raw := range doc.Messages {
		var m struct {
			ID        flexID    `json:"id"`
			Timestamp time.Time `json:"timestamp"`
			Label     string    `json:"label"`
		}
		if json.Unmarshal(raw, &m) != nil || m.ID <= 0 {
			continue
		}
		msgs = append(msgs, store.AcarsMessage{ID: int64(m.ID), Hex: hex, FlightID: flightID, Time: m.Timestamp.Unix(), Label: m.Label, Message: raw})
	}
	if n, err := s.Store.InsertAcars(ctx, msgs); err != nil {
		s.log.Warn("storing ACARS failed", "err", err)
	} else if n > 0 {
		s.log.Debug("stored ACARS messages", "new", n)
	}
}

// ---- /v1/metar, /v1/taf (aviationweather.gov) ----

// wxCache caches reports per station, so different station lists share entries. A station with
// no report is cached as nil (no repeated requests for it either).
type wxCache struct {
	mu sync.Mutex
	m  map[string]wxEntry
}

type wxEntry struct {
	rec   json.RawMessage // nil: no report
	fresh time.Time
	stale time.Time
}

func newWxCache() *wxCache { return &wxCache{m: map[string]wxEntry{}} }

func (c *wxCache) get(key string, now time.Time, allowStale bool) (json.RawMessage, bool) {
	c.mu.Lock()
	defer c.mu.Unlock()
	e, ok := c.m[key]
	if !ok || (now.After(e.fresh) && (!allowStale || now.After(e.stale))) {
		return nil, false
	}
	return e.rec, true
}

func (c *wxCache) put(key string, rec json.RawMessage, now time.Time, ttl time.Duration) {
	c.mu.Lock()
	defer c.mu.Unlock()
	c.m[key] = wxEntry{rec: rec, fresh: now.Add(ttl), stale: now.Add(3 * time.Hour)}
}

func (c *wxCache) sweep(now time.Time) {
	c.mu.Lock()
	defer c.mu.Unlock()
	for k, e := range c.m {
		if now.After(e.stale) {
			delete(c.m, k)
		}
	}
}

const maxStations = 20

func (s *Server) handleWeather(product string, ttl time.Duration) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		ids, ok := ParseICAOList(r.URL.Query().Get("ids"), maxStations)
		if !ok {
			writeError(w, r, http.StatusBadRequest, fmt.Sprintf("ids must be 1-%d comma-separated 4-character ICAO codes", maxStations))
			return
		}
		now := s.now()
		var missing []string
		for _, id := range ids {
			if _, ok := s.wx.get(product+":"+id, now, false); !ok {
				missing = append(missing, id)
			}
		}
		cacheState := "hit"
		if len(missing) > 0 {
			cacheState = "miss"
			_, _, err := s.live.Get(r.Context(), "wx:"+product+":"+strings.Join(missing, ","), func(ctx context.Context) (cache.Value, time.Duration, error) {
				u := s.Endpoints.AviationWeather + "/" + product + "?ids=" + strings.Join(missing, ",") + "&format=json"
				resp, err := s.Client.Get(ctx, upstream.AviationWeather, u)
				if err != nil {
					return cache.Value{}, 0, err
				}
				var recs []json.RawMessage
				switch resp.Status {
				case 200:
					if !isBlank(resp.Body) {
						if err := json.Unmarshal(resp.Body, &recs); err != nil {
							return cache.Value{}, 0, fmt.Errorf("aviationweather: %w", err)
						}
					}
				case 204: // no reports
				default:
					return cache.Value{}, 0, fmt.Errorf("aviationweather: HTTP %d", resp.Status)
				}
				t := s.now()
				found := map[string]json.RawMessage{}
				for _, rec := range recs {
					var head struct {
						ICAO string `json:"icaoId"`
					}
					if json.Unmarshal(rec, &head) == nil && head.ICAO != "" {
						id := strings.ToUpper(head.ICAO)
						if _, dup := found[id]; !dup { // the newest report comes first
							found[id] = rec
						}
					}
				}
				for _, id := range missing {
					s.wx.put(product+":"+id, found[id], t, ttl)
				}
				return cache.Value{Status: 200}, time.Second, nil
			})
			if err != nil {
				cacheState = "stale"
				if errors.Is(err, context.Canceled) {
					return
				}
				s.log.Warn("weather fetch failed", "product", product, "err", err)
			}
		}
		out := make([]json.RawMessage, 0, len(ids))
		anyKnown := false
		for _, id := range ids {
			if rec, ok := s.wx.get(product+":"+id, now, true); ok {
				anyKnown = true
				if rec != nil {
					out = append(out, rec)
				}
			}
		}
		if !anyKnown && cacheState == "stale" {
			writeError(w, r, http.StatusBadGateway, "aviationweather.gov unavailable")
			return
		}
		w.Header().Set("X-Cache", cacheState)
		writeJSON(w, r, http.StatusOK, out)
	}
}
