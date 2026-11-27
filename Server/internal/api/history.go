package api

import (
	"math"
	"net/http"
	"runtime"
	"time"

	"github.com/BadWasabeee/flightdesk/Server/internal/store"
	"github.com/BadWasabeee/flightdesk/Server/internal/upstream"
)

// SightingsResponse pages through the sightings log.
type SightingsResponse struct {
	Sightings  []*store.Sighting `json:"sightings"`
	Next       *SightingsCursor  `json:"next"` // null when this page is the last
	ServerTime int64             `json:"serverTime"`
}

// SightingsCursor is passed back as ?since=&after= for the next page.
type SightingsCursor struct {
	Since int64  `json:"since"`
	After string `json:"after"`
}

func (s *Server) handleSightings(w http.ResponseWriter, r *http.Request) {
	q := r.URL.Query()
	since, ok1 := parseInt(q.Get("since"), 0, 0, math.MaxInt32*4)
	limit, ok2 := parseInt(q.Get("limit"), 1000, 1, 5000)
	after := ""
	ok3 := true
	if v := q.Get("after"); v != "" {
		after, ok3 = ValidHex(v, false)
	}
	if !ok1 || !ok2 || !ok3 {
		writeError(w, r, http.StatusBadRequest, "since: Unix seconds; after: hex from the previous page; limit 1..5000")
		return
	}
	list, err := s.Store.SightingsSince(r.Context(), since, after, int(limit))
	if err != nil {
		writeError(w, r, http.StatusInternalServerError, "database error")
		return
	}
	resp := SightingsResponse{Sightings: list, ServerTime: s.now().Unix()}
	if int64(len(list)) == limit {
		last := list[len(list)-1]
		resp.Next = &SightingsCursor{Since: last.LastSeen, After: last.Hex}
	}
	writeJSON(w, r, http.StatusOK, resp)
}

func (s *Server) handleLegs(w http.ResponseWriter, r *http.Request) {
	q := r.URL.Query()
	lq := store.LegsQuery{}
	var ok [5]bool
	ok[0] = true
	if v := q.Get("hex"); v != "" {
		lq.Hex, ok[0] = ValidHex(v, true)
	}
	ok[1] = true
	if v := q.Get("callsign"); v != "" {
		lq.Callsign, ok[1] = ValidCallsign(v)
	}
	lq.Since, ok[2] = parseInt(q.Get("since"), 0, 0, math.MaxInt32*4)
	lq.Before, ok[3] = parseInt(q.Get("before"), 0, 0, math.MaxInt32*4)
	limit, okL := parseInt(q.Get("limit"), 200, 1, 1000)
	ok[4] = okL
	lq.Limit = int(limit)
	for _, b := range ok {
		if !b {
			writeError(w, r, http.StatusBadRequest, "hex (6 hex digits), callsign ([A-Z0-9]{2,8}), since/before (Unix seconds), limit 1..1000")
			return
		}
	}
	legs, err := s.Store.Legs(r.Context(), lq)
	if err != nil {
		writeError(w, r, http.StatusInternalServerError, "database error")
		return
	}
	if legs == nil {
		legs = []*store.Leg{}
	}
	writeJSON(w, r, http.StatusOK, map[string]any{"legs": legs})
}

func (s *Server) handleAcarsHistory(w http.ResponseWriter, r *http.Request) {
	q := r.URL.Query()
	hex, ok1 := ValidHex(q.Get("hex"), false)
	since, ok2 := parseInt(q.Get("since"), 0, 0, math.MaxInt32*4)
	limit, ok3 := parseInt(q.Get("limit"), 500, 1, 2000)
	if !ok1 || !ok2 || !ok3 {
		writeError(w, r, http.StatusBadRequest, "hex (6 hex digits) required; since: Unix seconds; limit 1..2000")
		return
	}
	msgs, err := s.Store.AcarsSince(r.Context(), hex, since, int(limit))
	if err != nil {
		writeError(w, r, http.StatusInternalServerError, "database error")
		return
	}
	writeJSON(w, r, http.StatusOK, map[string]any{"messages": msgs})
}

// ---- /v1/stats ----

func (s *Server) handleStats(w http.ResponseWriter, r *http.Request) {
	ctx := r.Context()
	now := s.now()
	sizes, err := s.Store.Sizes(ctx)
	if err != nil {
		writeError(w, r, http.StatusInternalServerError, "database error")
		return
	}
	// Row counts scan tables: refresh at most every 30 seconds.
	s.statsMu.Lock()
	if s.statsCache == nil || now.Sub(s.statsAt) > 30*time.Second {
		if c, err := s.Store.Counts(ctx, now); err == nil {
			s.statsCache, s.statsAt = &c, now
		}
	}
	counts := s.statsCache
	s.statsMu.Unlock()

	day, svc := s.Client.Stats()
	services := map[string]upstream.ServiceStats{}
	total := 0
	for _, name := range upstream.Services {
		st := svc[name]
		services[string(name)] = st
		total += st.Requests
	}
	var ms runtime.MemStats
	runtime.ReadMemStats(&ms)
	watches := s.Poller.Watches()
	resp := map[string]any{
		"version":       s.Version,
		"now":           now.Unix(),
		"uptimeSeconds": int64(now.Sub(s.boot).Seconds()),
		"db": map[string]any{
			"path":         s.Store.Path(),
			"sizes":        sizes,
			"totalBytes":   sizes.Total(),
			"diskCapBytes": s.cfg.DiskCapBytes(),
			"counts":       counts,
		},
		"upstream": map[string]any{"day": day, "totalRequests": total, "services": services},
		"poller":   s.Poller.Health(),
		"watches":  map[string]any{"active": len(watches), "max": s.Poller.MaxWatches(), "list": watches},
		"tracker":  s.Tracker.Stats(),
		"caches": map[string]int{
			"nearby": s.nearby.Len(), "live": s.live.Len(), "lookupsInFlight": s.lookups.Len(),
		},
		"memory": map[string]uint64{"heapAllocBytes": ms.HeapAlloc, "sysBytes": ms.Sys, "numGC": uint64(ms.NumGC)},
		"retention": map[string]int{
			"detailDays": s.cfg.RetainDetailDays, "coarseDays": s.cfg.RetainCoarseDays, "acarsDays": s.cfg.RetainAcarsDays,
		},
	}
	if s.Maintenance != nil {
		resp["lastMaintenance"] = s.Maintenance()
	}
	writeJSON(w, r, http.StatusOK, resp)
}
