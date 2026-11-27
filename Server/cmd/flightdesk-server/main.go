// Command flightdesk-server is the self-hosted FlightDesk server: it polls the live ADS-B feeds
// for one area, proxies and caches the other free APIs the apps use, and keeps a compact flight
// history in SQLite.
//
// Usage:
//
//	flightdesk-server [serve] [-config /etc/flightdesk/flightdesk.env]
//	flightdesk-server token
//	flightdesk-server check -config /etc/flightdesk/flightdesk.env
//	flightdesk-server version
package main

import (
	"context"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"log/slog"
	"net"
	"net/http"
	"os"
	"os/signal"
	"strings"
	"sync"
	"syscall"
	"time"

	"github.com/BadWasabeee/flightdesk/Server/internal/api"
	"github.com/BadWasabeee/flightdesk/Server/internal/config"
	"github.com/BadWasabeee/flightdesk/Server/internal/poller"
	"github.com/BadWasabeee/flightdesk/Server/internal/store"
	"github.com/BadWasabeee/flightdesk/Server/internal/tracker"
	"github.com/BadWasabeee/flightdesk/Server/internal/upstream"
)

// version is set at build time with -ldflags "-X main.version=...".
var version = "dev"

func main() {
	args := os.Args[1:]
	cmd := "serve"
	if len(args) > 0 && !strings.HasPrefix(args[0], "-") {
		cmd, args = args[0], args[1:]
	}
	var err error
	switch cmd {
	case "serve":
		err = serve(args)
	case "token":
		var t string
		if t, err = config.NewToken(); err == nil {
			fmt.Println(t)
		}
	case "check":
		err = check(args)
	case "version":
		fmt.Println(version)
	case "help", "-h", "--help":
		usage()
	default:
		usage()
		os.Exit(2)
	}
	if err != nil {
		fmt.Fprintln(os.Stderr, "flightdesk-server:", err)
		os.Exit(1)
	}
}

func usage() {
	fmt.Fprint(os.Stderr, `flightdesk-server: self-hosted flight data cache and history for FlightDesk

  flightdesk-server [serve] [-config FILE]   run the server
  flightdesk-server token                    print a new random bearer token
  flightdesk-server check -config FILE       validate a configuration file
  flightdesk-server version                  print the version

Configuration comes from FLIGHTDESK_* variables, read from -config FILE and the environment.
`)
}

func loadConfig(args []string, name string) (config.Config, error) {
	fs := flag.NewFlagSet(name, flag.ContinueOnError)
	path := fs.String("config", os.Getenv("FLIGHTDESK_CONFIG"), "env file with FLIGHTDESK_* settings")
	if err := fs.Parse(args); err != nil {
		return config.Config{}, err
	}
	return config.Load(*path, os.Environ())
}

func check(args []string) error {
	cfg, err := loadConfig(args, "check")
	if err != nil {
		return err
	}
	area := "off"
	if cfg.AreaEnabled() {
		area = fmt.Sprintf("%.4f, %.4f radius %d nm every %s", cfg.CenterLat, cfg.CenterLon, cfg.RadiusNM, cfg.PollInterval)
	}
	fmt.Printf("configuration OK\n  listen   %s\n  data     %s\n  area     %s\n  cap      %.1f GB\n", cfg.Listen, cfg.DataDir, area, cfg.DiskCapGB)
	return nil
}

func newLogger(cfg config.Config) *slog.Logger {
	var lvl slog.Level
	if err := lvl.UnmarshalText([]byte(cfg.LogLevel)); err != nil {
		lvl = slog.LevelInfo
	}
	opts := &slog.HandlerOptions{Level: lvl}
	if cfg.LogFormat == "text" {
		return slog.New(slog.NewTextHandler(os.Stderr, opts))
	}
	return slog.New(slog.NewJSONHandler(os.Stderr, opts))
}

const countsKey = "upstream.counts.v1"

type savedCounts struct {
	Day    string         `json:"day"`
	Counts map[string]int `json:"counts"`
}

func serve(args []string) error {
	cfg, err := loadConfig(args, "serve")
	if err != nil {
		return err // includes the refusal to start without a strong token
	}
	log := newLogger(cfg)
	slog.SetDefault(log)
	if !cfg.ListenIsLoopback() {
		log.Warn("listening on a non-loopback address: put TLS (nginx, Caddy) or a VPN in front; the token travels in every request",
			"listen", cfg.Listen)
	}

	ctx, stop := signal.NotifyContext(context.Background(), syscall.SIGINT, syscall.SIGTERM)
	defer stop()

	st, err := store.Open(ctx, cfg.DataDir)
	if err != nil {
		return err
	}
	defer st.Close()

	client := upstream.New(cfg.UserAgent, 20*time.Second, nil)
	if b, ok, _ := st.KVGet(ctx, countsKey); ok {
		var sc savedCounts
		if json.Unmarshal(b, &sc) == nil {
			client.Restore(sc.Day, sc.Counts)
		}
	}
	saveCounts := func(ctx context.Context) {
		day, counts := client.Counts()
		if b, err := json.Marshal(savedCounts{Day: day, Counts: counts}); err == nil {
			_ = st.KVPut(ctx, countsKey, b)
		}
	}

	ep := upstream.DefaultEndpoints
	routes := api.NewRouteMemo(5000)
	tr := tracker.New(tracker.Config{CenterLat: cfg.CenterLat, CenterLon: cfg.CenterLon, RadiusNM: float64(cfg.RadiusNM)}, st, routes.Lookup, log)
	if err := tr.Resume(ctx, time.Now()); err != nil {
		log.Warn("resuming active legs failed", "err", err)
	}
	feeds := poller.NewFeeds(client, ep)
	pl := poller.New(poller.Config{
		CenterLat: cfg.CenterLat, CenterLon: cfg.CenterLon, RadiusNM: cfg.RadiusNM,
		Interval: cfg.PollInterval, WatchInterval: cfg.WatchInterval, MaxWatches: cfg.MaxWatches,
	}, feeds, tr, st, log)

	maint := &maintenance{st: st, cfg: cfg, log: log}
	srv := api.New(api.Deps{
		Config: cfg, Store: st, Client: client, Endpoints: ep, Feeds: feeds, Poller: pl, Tracker: tr,
		Routes: routes, Log: log, Version: version, Maintenance: maint.last,
	})
	httpSrv := &http.Server{
		Addr:              cfg.Listen,
		Handler:           srv.Handler(),
		ReadHeaderTimeout: 5 * time.Second,
		ReadTimeout:       10 * time.Second,
		WriteTimeout:      60 * time.Second,
		IdleTimeout:       120 * time.Second,
		MaxHeaderBytes:    16 << 10,
		ErrorLog:          slog.NewLogLogger(log.Handler(), slog.LevelWarn),
		BaseContext:       func(net.Listener) context.Context { return ctx },
	}
	ln, err := net.Listen("tcp", cfg.Listen)
	if err != nil {
		return err
	}
	log.Info("flightdesk-server starting", "version", version, "listen", cfg.Listen, "data", cfg.DataDir,
		"area", cfg.AreaEnabled(), "radiusNM", cfg.RadiusNM, "poll", cfg.PollInterval.String(), "capGB", cfg.DiskCapGB)

	var wg sync.WaitGroup
	wg.Go(func() { pl.Run(ctx) })
	wg.Go(func() { maint.run(ctx) })
	wg.Go(func() {
		t := time.NewTicker(time.Minute)
		defer t.Stop()
		for i := 0; ; i++ {
			select {
			case <-ctx.Done():
				return
			case <-t.C:
				saveCounts(ctx)
				if i%5 == 0 {
					srv.SweepCaches()
				}
			}
		}
	})

	errc := make(chan error, 1)
	go func() { errc <- httpSrv.Serve(ln) }()
	select {
	case <-ctx.Done():
	case err := <-errc:
		if !errors.Is(err, http.ErrServerClosed) {
			log.Error("http server failed", "err", err)
			stop()
		}
	}
	log.Info("shutting down")
	sctx, cancel := context.WithTimeout(context.Background(), 15*time.Second)
	defer cancel()
	_ = httpSrv.Shutdown(sctx)
	wg.Wait() // the poller flushes pending track points on the way out
	saveCounts(sctx)
	log.Info("stopped")
	return nil
}

// maintenance runs retention nightly and checks the disk cap hourly.
type maintenance struct {
	st  *store.Store
	cfg config.Config
	log *slog.Logger

	mu     sync.Mutex
	report map[string]any
}

func (m *maintenance) last() any {
	m.mu.Lock()
	defer m.mu.Unlock()
	return m.report
}

func (m *maintenance) run(ctx context.Context) {
	// A cap check shortly after start, then hourly; full retention once a night.
	timer := time.NewTimer(2 * time.Minute)
	defer timer.Stop()
	lastNightly := ""
	for {
		select {
		case <-ctx.Done():
			return
		case <-timer.C:
		}
		now := time.Now()
		day := now.Format("2006-01-02")
		if now.Hour() == m.cfg.MaintenanceHour && day != lastNightly {
			lastNightly = day
			m.retention(ctx, now)
		}
		m.enforceCap(ctx, now)
		timer.Reset(time.Hour - time.Duration(now.Minute())*time.Minute + time.Minute) // just after the next hour
	}
}

func (m *maintenance) retention(ctx context.Context, now time.Time) {
	start := time.Now()
	rep, err := m.st.ApplyRetention(ctx, now, store.Retention{
		DetailDays: m.cfg.RetainDetailDays, CoarseDays: m.cfg.RetainCoarseDays, AcarsDays: m.cfg.RetainAcarsDays,
	})
	if err != nil {
		m.log.Error("retention failed", "err", err)
		return
	}
	m.log.Info("retention done", "downsampledLegs", rep.Downsampled, "droppedTracks", rep.TracksDropped,
		"droppedOpenSky", rep.OpenSkyDropped, "deletedAcars", rep.AcarsDeleted, "deletedLookups", rep.LookupsDeleted,
		"bytesBefore", rep.BytesBefore, "bytesAfter", rep.BytesAfter, "ms", time.Since(start).Milliseconds())
	m.record("retention", now, rep)
}

func (m *maintenance) enforceCap(ctx context.Context, now time.Time) {
	rep, err := m.st.EnforceCap(ctx, now, m.cfg.DiskCapBytes(), 7, 300)
	if err != nil {
		m.log.Error("disk cap check failed", "err", err)
		return
	}
	if !rep.CapExceeded {
		return
	}
	attrs := []any{"capBytes", m.cfg.DiskCapBytes(), "downsampledLegs", rep.Downsampled, "droppedTracks", rep.TracksDropped,
		"deletedAcars", rep.AcarsDeleted, "bytesBefore", rep.BytesBefore, "bytesAfter", rep.BytesAfter}
	if rep.OldestTouchedAt > 0 {
		attrs = append(attrs, "prunedFrom", time.Unix(rep.OldestTouchedAt, 0).UTC().Format(time.DateOnly),
			"prunedTo", time.Unix(rep.NewestTouchedAt, 0).UTC().Format(time.DateOnly))
	}
	if rep.CapUnreachable {
		m.log.Error("disk cap exceeded and cannot be met by pruning tracks/ACARS; raise FLIGHTDESK_DISK_CAP_GB", attrs...)
	} else {
		m.log.Warn("disk cap exceeded: pruned oldest detail", attrs...)
	}
	m.record("cap", now, rep)
}

func (m *maintenance) record(kind string, at time.Time, rep store.Report) {
	m.mu.Lock()
	defer m.mu.Unlock()
	if m.report == nil {
		m.report = map[string]any{}
	}
	m.report[kind] = map[string]any{"at": at.Unix(), "report": rep}
}
