package poller

import (
	"context"
	"encoding/json"
	"errors"
	"log/slog"
	"maps"
	"slices"
	"sync"
	"sync/atomic"
	"time"

	"github.com/BadWasabeee/flightdesk/Server/internal/adsb"
	"github.com/BadWasabeee/flightdesk/Server/internal/store"
	"github.com/BadWasabeee/flightdesk/Server/internal/tracker"
	"github.com/BadWasabeee/flightdesk/Server/internal/upstream"
)

// Config configures polling.
type Config struct {
	CenterLat, CenterLon float64
	RadiusNM             int           // 0 disables the area poller
	Interval             time.Duration // area poll interval
	WatchInterval        time.Duration
	FlushInterval        time.Duration
	MaxWatches           int
	WatchMissing         time.Duration // stop a watch after this long unseen
	WatchMaxAge          time.Duration // stop a watch after this long regardless
	WatchParked          time.Duration // stop a watch on an aircraft that never leaves the ground
}

func (c Config) withDefaults() Config {
	if c.Interval <= 0 {
		c.Interval = 8 * time.Second
	}
	if c.WatchInterval <= 0 {
		c.WatchInterval = 45 * time.Second
	}
	if c.FlushInterval <= 0 {
		c.FlushInterval = time.Minute
	}
	if c.MaxWatches <= 0 {
		c.MaxWatches = 20
	}
	if c.WatchMissing <= 0 {
		c.WatchMissing = 30 * time.Minute
	}
	if c.WatchMaxAge <= 0 {
		c.WatchMaxAge = 18 * time.Hour
	}
	if c.WatchParked <= 0 {
		c.WatchParked = time.Hour
	}
	return c
}

// Snapshot is the latest area poll.
type Snapshot struct {
	Time    time.Time        // the feed's timestamp
	Source  upstream.Service // feed that answered
	Flights []adsb.Flight    // distance/bearing unset; see Flight.Locate
}

// Health describes the area poller.
type Health struct {
	Enabled             bool       `json:"enabled"`
	CenterLat           float64    `json:"centerLat"`
	CenterLon           float64    `json:"centerLon"`
	RadiusNM            int        `json:"radiusNM"`
	IntervalSeconds     float64    `json:"intervalSeconds"`
	LastSuccess         *time.Time `json:"lastSuccess,omitempty"`
	LastAttempt         *time.Time `json:"lastAttempt,omitempty"`
	LastError           string     `json:"lastError,omitempty"`
	LastSource          string     `json:"lastSource,omitempty"`
	LastDurationMs      int64      `json:"lastDurationMs"`
	Aircraft            int        `json:"aircraft"`
	ConsecutiveFailures int        `json:"consecutiveFailures"`
	Polls               int64      `json:"polls"`
	Failures            int64      `json:"failures"`
	FlushError          string     `json:"flushError,omitempty"`
}

// Watch is a flight followed outside the area.
type Watch struct {
	Hex          string    `json:"hex"`
	Added        time.Time `json:"added"`
	LastSeen     time.Time `json:"lastSeen,omitzero"`
	LastPolled   time.Time `json:"lastPolled,omitzero"`
	SeenAirborne bool      `json:"seenAirborne"`
	OnGround     bool      `json:"onGround"`
}

// ErrWatchLimit is returned when the concurrent watch cap is reached.
var ErrWatchLimit = errors.New("watch limit reached")

// KV persists watches across restarts.
type KV interface {
	KVGet(ctx context.Context, key string) ([]byte, bool, error)
	KVPut(ctx context.Context, key string, value []byte) error
}

const watchesKey = "watches.v1"

// Poller is safe for concurrent use.
type Poller struct {
	cfg   Config
	feeds *Feeds
	tr    *tracker.Tracker
	kv    KV
	log   *slog.Logger
	now   func() time.Time

	snap atomic.Pointer[Snapshot]

	mu      sync.Mutex
	health  Health
	watches map[string]*Watch
}

// New makes a poller. kv may be nil.
func New(cfg Config, feeds *Feeds, tr *tracker.Tracker, kv KV, log *slog.Logger) *Poller {
	cfg = cfg.withDefaults()
	if log == nil {
		log = slog.Default()
	}
	p := &Poller{cfg: cfg, feeds: feeds, tr: tr, kv: kv, log: log, now: time.Now, watches: map[string]*Watch{}}
	p.health = Health{Enabled: cfg.RadiusNM > 0, CenterLat: cfg.CenterLat, CenterLon: cfg.CenterLon,
		RadiusNM: cfg.RadiusNM, IntervalSeconds: cfg.Interval.Seconds()}
	return p
}

// Config returns the effective configuration.
func (p *Poller) Config() Config { return p.cfg }

// Snapshot returns the latest area snapshot (nil before the first successful poll).
func (p *Poller) Snapshot() *Snapshot { return p.snap.Load() }

// Health returns poller health.
func (p *Poller) Health() Health {
	p.mu.Lock()
	defer p.mu.Unlock()
	return p.health
}

// Run polls until ctx is cancelled, then flushes pending track data.
func (p *Poller) Run(ctx context.Context) {
	p.loadWatches(ctx)
	area := time.NewTicker(p.cfg.Interval)
	watch := time.NewTicker(p.cfg.WatchInterval)
	flush := time.NewTicker(p.cfg.FlushInterval)
	defer area.Stop()
	defer watch.Stop()
	defer flush.Stop()
	if p.cfg.RadiusNM > 0 {
		p.PollArea(ctx)
	} else {
		area.Stop()
		p.log.Warn("no area configured: the area poller is off; only proxying and watches run")
	}
	for {
		select {
		case <-ctx.Done():
			fctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
			p.flush(fctx)
			p.saveWatches(fctx)
			cancel()
			return
		case <-area.C:
			p.PollArea(ctx)
		case <-watch.C:
			p.PollWatches(ctx)
		case <-flush.C:
			p.flush(ctx)
		}
	}
}

func (p *Poller) flush(ctx context.Context) {
	err := p.tr.Flush(ctx, p.now())
	p.mu.Lock()
	p.health.FlushError = ""
	if err != nil {
		p.health.FlushError = err.Error()
	}
	p.mu.Unlock()
	if err != nil {
		p.log.Error("flushing tracks failed", "err", err)
	}
}

// PollArea runs one area poll.
func (p *Poller) PollArea(ctx context.Context) {
	start := p.now()
	ctx, cancel := context.WithTimeout(ctx, max(p.cfg.Interval*2, 20*time.Second))
	defer cancel()
	resp, src, err := p.feeds.Point(ctx, p.cfg.CenterLat, p.cfg.CenterLon, p.cfg.RadiusNM, 4)
	now := p.now()
	p.mu.Lock()
	p.health.Polls++
	p.health.LastAttempt = &now
	p.health.LastDurationMs = now.Sub(start).Milliseconds()
	if err != nil {
		p.health.Failures++
		p.health.ConsecutiveFailures++
		p.health.LastError = err.Error()
		fails := p.health.ConsecutiveFailures
		p.mu.Unlock()
		if fails == 1 || fails%30 == 0 {
			p.log.Warn("area poll failed", "err", err, "consecutive", fails)
		}
		return
	}
	flights := adsb.Flights(resp, now)
	p.health.ConsecutiveFailures = 0
	p.health.LastError = ""
	p.health.LastSuccess = &now
	p.health.LastSource = string(src)
	p.health.Aircraft = len(flights)
	p.mu.Unlock()
	p.snap.Store(&Snapshot{Time: resp.Time(now), Source: src, Flights: flights})
	p.tr.Observe(ctx, flights, store.SourceArea)
}

// AddWatch starts (or refreshes) following hex. hex must already be validated.
func (p *Poller) AddWatch(ctx context.Context, hex string) (Watch, int, error) {
	p.mu.Lock()
	if w, ok := p.watches[hex]; ok {
		cp := *w
		n := len(p.watches)
		p.mu.Unlock()
		return cp, n, nil
	}
	if len(p.watches) >= p.cfg.MaxWatches {
		n := len(p.watches)
		p.mu.Unlock()
		return Watch{}, n, ErrWatchLimit
	}
	w := &Watch{Hex: hex, Added: p.now().UTC()}
	p.watches[hex] = w
	cp, n := *w, len(p.watches)
	p.mu.Unlock()
	p.log.Info("watch started", "hex", hex, "active", n)
	p.saveWatches(ctx)
	return cp, n, nil
}

// RemoveWatch stops following hex.
func (p *Poller) RemoveWatch(ctx context.Context, hex string) bool {
	p.mu.Lock()
	_, ok := p.watches[hex]
	delete(p.watches, hex)
	p.mu.Unlock()
	if ok {
		p.saveWatches(ctx)
	}
	return ok
}

// Watches lists active watches.
func (p *Poller) Watches() []Watch {
	p.mu.Lock()
	defer p.mu.Unlock()
	out := make([]Watch, 0, len(p.watches))
	for _, k := range slices.Sorted(maps.Keys(p.watches)) {
		out = append(out, *p.watches[k])
	}
	return out
}

// MaxWatches is the cap.
func (p *Poller) MaxWatches() int { return p.cfg.MaxWatches }

// PollWatches updates every watch: from the area snapshot when the aircraft is in it (no
// request), otherwise with one batched adsb.fi request for all the others.
func (p *Poller) PollWatches(ctx context.Context) {
	now := p.now()
	inArea := map[string]adsb.Flight{}
	if s := p.Snapshot(); s != nil && now.Sub(s.Time) < 3*p.cfg.Interval {
		for _, f := range s.Flights {
			inArea[f.ID] = f
		}
	}
	p.mu.Lock()
	var need []string
	for hex, w := range p.watches {
		if f, ok := inArea[hex]; ok {
			p.updateWatchLocked(w, f, now)
		} else {
			need = append(need, hex)
		}
	}
	p.mu.Unlock()
	slices.Sort(need)

	found := map[string]adsb.Flight{}
	for chunk := range slices.Chunk(need, 25) {
		cctx, cancel := context.WithTimeout(ctx, 20*time.Second)
		resp, err := p.feeds.Hexes(cctx, chunk)
		cancel()
		if err != nil {
			p.log.Warn("watch poll failed", "err", err, "hexes", len(chunk))
			break
		}
		fl := adsb.Flights(resp, now)
		p.tr.Observe(ctx, fl, store.SourceWatch)
		for _, f := range fl {
			found[f.ID] = f
		}
	}

	changed := false
	p.mu.Lock()
	for _, hex := range need {
		if w, ok := p.watches[hex]; ok {
			w.LastPolled = now
			if f, ok := found[hex]; ok {
				p.updateWatchLocked(w, f, now)
			}
		}
	}
	for hex, w := range p.watches {
		if reason := p.watchDone(w, now); reason != "" {
			delete(p.watches, hex)
			changed = true
			p.log.Info("watch ended", "hex", hex, "reason", reason)
		}
	}
	p.mu.Unlock()
	if changed {
		p.saveWatches(ctx)
	}
}

func (p *Poller) updateWatchLocked(w *Watch, f adsb.Flight, now time.Time) {
	w.LastSeen = now
	w.OnGround = f.OnGround
	if !f.OnGround {
		w.SeenAirborne = true
	}
}

// watchDone returns why a watch should stop, or "".
func (p *Poller) watchDone(w *Watch, now time.Time) string {
	last := w.LastSeen
	if last.IsZero() {
		last = w.Added
	}
	switch {
	case w.SeenAirborne && w.OnGround:
		return "landed"
	case now.Sub(last) > p.cfg.WatchMissing:
		return "not seen for " + p.cfg.WatchMissing.String()
	case now.Sub(w.Added) > p.cfg.WatchMaxAge:
		return "maximum watch age"
	case !w.SeenAirborne && w.OnGround && now.Sub(w.Added) > p.cfg.WatchParked:
		return "never left the ground"
	}
	return ""
}

func (p *Poller) saveWatches(ctx context.Context) {
	if p.kv == nil {
		return
	}
	b, err := json.Marshal(p.Watches())
	if err == nil {
		err = p.kv.KVPut(ctx, watchesKey, b)
	}
	if err != nil {
		p.log.Warn("saving watches failed", "err", err)
	}
}

func (p *Poller) loadWatches(ctx context.Context) {
	if p.kv == nil {
		return
	}
	b, ok, err := p.kv.KVGet(ctx, watchesKey)
	if err != nil || !ok {
		return
	}
	var list []Watch
	if json.Unmarshal(b, &list) != nil {
		return
	}
	p.mu.Lock()
	defer p.mu.Unlock()
	for i := range list {
		if len(p.watches) >= p.cfg.MaxWatches {
			break
		}
		w := list[i]
		if p.watchDone(&w, p.now()) == "" && adsb.ValidFeedHex(w.Hex) {
			p.watches[w.Hex] = &w
		}
	}
	if len(p.watches) > 0 {
		p.log.Info("restored watches", "count", len(p.watches))
	}
}

// SetClock replaces the clock (tests).
func (p *Poller) SetClock(now func() time.Time) { p.now = now }
