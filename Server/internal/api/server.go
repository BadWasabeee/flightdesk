// Package api is the device-facing HTTP API.
package api

import (
	"log/slog"
	"net/http"
	"sync"
	"time"

	"github.com/BadWasabeee/flightdesk/Server/internal/cache"
	"github.com/BadWasabeee/flightdesk/Server/internal/config"
	"github.com/BadWasabeee/flightdesk/Server/internal/poller"
	"github.com/BadWasabeee/flightdesk/Server/internal/store"
	"github.com/BadWasabeee/flightdesk/Server/internal/tracker"
	"github.com/BadWasabeee/flightdesk/Server/internal/upstream"
)

// Deps are the server's collaborators.
type Deps struct {
	Config    config.Config
	Store     *store.Store
	Client    *upstream.Client
	Endpoints upstream.Endpoints
	Feeds     *poller.Feeds
	Poller    *poller.Poller
	Tracker   *tracker.Tracker
	Routes    *RouteMemo
	Log       *slog.Logger
	Version   string
	// Maintenance returns the last maintenance report for /v1/stats (may be nil).
	Maintenance func() any
}

// Server handles API requests.
type Server struct {
	Deps
	cfg  config.Config
	log  *slog.Logger
	now  func() time.Time
	boot time.Time

	rate      *limiter
	authFails *limiter

	nearby  *cache.Group // proxied nearby queries, 5 s
	lookups *cache.Group // coalesces adsbdb / airframe-id fetches (persisted in the DB)
	live    *cache.Group // airframes records, OpenSky by hex, ...
	wx      *wxCache

	statsMu    sync.Mutex
	statsAt    time.Time
	statsCache *store.Counts
}

// New builds a server.
func New(d Deps) *Server {
	if d.Log == nil {
		d.Log = slog.Default()
	}
	if d.Routes == nil {
		d.Routes = NewRouteMemo(5000)
	}
	perMin := float64(d.Config.RateLimitPerMin)
	return &Server{
		Deps:      d,
		cfg:       d.Config,
		log:       d.Log,
		now:       time.Now,
		boot:      time.Now(),
		rate:      newLimiter(perMin, max(20, perMin/4)),
		authFails: newLimiter(1, 10), // 10 failures, then one more per minute
		nearby:    cache.New(500, time.Minute, 20*time.Second),
		lookups:   cache.New(2000, 0, 20*time.Second),
		live:      cache.New(1000, 10*time.Minute, 30*time.Second),
		wx:        newWxCache(),
	}
}

// Handler returns the routed handler with all middleware.
func (s *Server) Handler() http.Handler {
	mux := http.NewServeMux()
	p := func(pattern string, h http.HandlerFunc) { mux.Handle(pattern, s.protect(h)) }

	mux.HandleFunc("GET /healthz", s.healthz)
	p("GET /v1/nearby", s.handleNearby)
	p("GET /v1/track/{hex}", s.handleTrack)
	p("GET /v1/route/{callsign}", s.handleRoute)
	p("GET /v1/aircraft/{hex}", s.handleAircraft)
	p("GET /v1/acars/{id}", s.handleAcars)
	p("GET /v1/metar", s.handleWeather("metar", 10*time.Minute))
	p("GET /v1/taf", s.handleWeather("taf", 30*time.Minute))
	p("GET /v1/watch", s.handleWatchList)
	p("POST /v1/watch/{hex}", s.handleWatchAdd)
	p("DELETE /v1/watch/{hex}", s.handleWatchRemove)
	p("GET /v1/history/sightings", s.handleSightings)
	p("GET /v1/history/legs", s.handleLegs)
	p("GET /v1/history/acars", s.handleAcarsHistory)
	p("GET /v1/stats", s.handleStats)
	mux.Handle("/", s.protect(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		writeError(w, r, http.StatusNotFound, "not found")
	})))
	return s.common(mux)
}

func (s *Server) healthz(w http.ResponseWriter, r *http.Request) {
	writeJSON(w, r, http.StatusOK, map[string]bool{"ok": true})
}

// SweepCaches drops expired cache entries; call periodically.
func (s *Server) SweepCaches() {
	s.nearby.Sweep()
	s.lookups.Sweep()
	s.live.Sweep()
	s.wx.sweep(s.now())
}
