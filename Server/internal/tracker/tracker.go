// Package tracker turns a stream of live observations into flight legs with simplified,
// compactly-encoded tracks, and maintains the sightings log. It is the only writer of legs,
// tracks and sightings; it buffers encoded points in memory and flushes them in batches.
package tracker

import (
	"context"
	"log/slog"
	"math"
	"slices"
	"strings"
	"sync"
	"time"

	"github.com/BadWasabeee/flightdesk/Server/internal/adsb"
	"github.com/BadWasabeee/flightdesk/Server/internal/geo"
	"github.com/BadWasabeee/flightdesk/Server/internal/store"
	"github.com/BadWasabeee/flightdesk/Server/internal/trackenc"
)

// Store is the persistence the tracker needs.
type Store interface {
	WriteBatch(ctx context.Context, legs []store.LegWrite, sightings []*store.Sighting) error
	LegsSeenSince(ctx context.Context, since int64) ([]*store.Leg, error)
	TrackBlobWriter(ctx context.Context, legID int64) ([]byte, error)
	Sighting(ctx context.Context, hex string) (*store.Sighting, error)
}

// RouteFunc returns a known route for a callsign without fetching (origin/destination codes).
type RouteFunc func(callsign string) (origin, dest string, ok bool)

// Config tunes leg detection.
type Config struct {
	CenterLat, CenterLon float64
	RadiusNM             float64 // 0 = no area (sightings disabled, min distance unknown)

	// LegGap: unseen this long ends a leg (and starts a new sighting visit).
	LegGap time.Duration
	// Turnaround: on the ground this long after flying, then airborne again, starts a new leg.
	Turnaround time.Duration
	// MaxLeg splits implausibly long legs (e.g. a vehicle transponder left on).
	MaxLeg time.Duration
	// MaxImpliedKt rejects position glitches implying a faster jump than this.
	MaxImpliedKt float64

	Simplifier trackenc.Simplifier
}

// DefaultConfig fills unset fields.
func (c Config) withDefaults() Config {
	if c.LegGap <= 0 {
		c.LegGap = 30 * time.Minute
	}
	if c.Turnaround <= 0 {
		c.Turnaround = 10 * time.Minute
	}
	if c.MaxLeg <= 0 {
		c.MaxLeg = 20 * time.Hour
	}
	if c.MaxImpliedKt <= 0 {
		c.MaxImpliedKt = 1500
	}
	if c.Simplifier == (trackenc.Simplifier{}) {
		c.Simplifier = trackenc.DefaultSimplifier
	}
	return c
}

const (
	callsignLimit = 8  // as SpottingLog.callsignLimit
	routeLimit    = 12 // as SpottingLog.routeLimit
)

type legState struct {
	leg         store.Leg
	enc         *trackenc.Encoder
	pending     []byte
	pendingN    int
	lastStored  trackenc.Point
	hasStored   bool
	lastSeen    trackenc.Point
	seenStored  bool
	groundSince int64
	wasAirborne bool
	dirty       bool
}

type sightingState struct {
	s     store.Sighting
	dirty bool
}

// Tracker is safe for concurrent use.
type Tracker struct {
	cfg    Config
	st     Store
	routes RouteFunc
	log    *slog.Logger

	mu        sync.Mutex
	legs      map[string]*legState
	closing   []*legState
	sightings map[string]*sightingState

	pointsSeen, pointsKept int64
}

// New makes a tracker. routes may be nil.
func New(cfg Config, st Store, routes RouteFunc, log *slog.Logger) *Tracker {
	if log == nil {
		log = slog.Default()
	}
	return &Tracker{
		cfg:       cfg.withDefaults(),
		st:        st,
		routes:    routes,
		log:       log,
		legs:      make(map[string]*legState),
		sightings: make(map[string]*sightingState),
	}
}

// Resume reloads legs that were active before a restart, so their tracks continue.
func (t *Tracker) Resume(ctx context.Context, now time.Time) error {
	legs, err := t.st.LegsSeenSince(ctx, now.Add(-t.cfg.LegGap).Unix())
	if err != nil {
		return err
	}
	t.mu.Lock()
	defer t.mu.Unlock()
	for _, l := range legs {
		blob, err := t.st.TrackBlobWriter(ctx, l.ID)
		if err != nil {
			return err
		}
		enc, last, ok, err := trackenc.Resume(l.FirstSeen, blob)
		if err != nil || !ok {
			continue // a leg without a usable track just starts afresh
		}
		ls := &legState{leg: *l, enc: enc, lastStored: last, hasStored: true, lastSeen: last, seenStored: true,
			wasAirborne: l.MaxAlt > 0}
		if last.Ground {
			ls.groundSince = last.T
		}
		t.legs[l.Hex] = ls
	}
	if len(legs) > 0 {
		t.log.Info("resumed active legs", "count", len(t.legs))
	}
	return nil
}

// PointFrom converts a live flight to a track point.
func PointFrom(f adsb.Flight) trackenc.Point {
	p := trackenc.Point{
		T:       int64(math.Round(f.PositionTime)),
		Lat:     f.Lat,
		Lon:     f.Lon,
		AltFt:   f.Altitude,
		SpeedKt: int(math.Round(f.Speed)),
		Track:   trackenc.TrackUnknown,
		Ground:  f.OnGround,
	}
	if f.OnGround {
		p.AltFt = 0
	}
	if f.Track != nil && !math.IsNaN(*f.Track) {
		p.Track = int(math.Round(math.Mod(*f.Track+360, 360))) % 360
	}
	return p
}

// Observe records one poll's flights from source (store.SourceArea or store.SourceWatch).
func (t *Tracker) Observe(ctx context.Context, flights []adsb.Flight, source int) {
	t.mu.Lock()
	defer t.mu.Unlock()
	for i := range flights {
		t.observeLocked(ctx, &flights[i], source)
	}
}

func (t *Tracker) observeLocked(ctx context.Context, f *adsb.Flight, source int) {
	p := PointFrom(*f)
	ls := t.legs[f.ID]
	if ls != nil && t.endsLeg(ls, p) {
		t.closeLocked(ls)
		ls = nil
	}
	if ls == nil {
		ls = &legState{leg: store.Leg{Hex: f.ID, FirstSeen: p.T, LastSeen: p.T, MinDist: -1}, enc: trackenc.NewEncoder(p.T)}
		t.legs[f.ID] = ls
	}
	t.pointsSeen++
	if p.T > ls.lastSeen.T || !ls.hasStored {
		if ls.hasStored && t.glitch(ls.lastSeen, p) {
			return
		}
		if !ls.hasStored || t.cfg.Simplifier.Keep(ls.lastStored, p) {
			var err error
			if ls.pending, err = ls.enc.Append(ls.pending, p); err == nil {
				ls.pendingN++
				ls.lastStored, ls.hasStored = p, true
				t.pointsKept++
			}
		}
		ls.seenStored = ls.hasStored && ls.lastStored.T == p.T
		ls.lastSeen = p
		if p.Ground {
			if ls.groundSince == 0 {
				ls.groundSince = p.T
			}
		} else {
			ls.groundSince = 0
			ls.wasAirborne = true
		}
	}
	l := &ls.leg
	if f.Callsign != "" {
		l.Callsign = f.Callsign
	}
	if f.Reg != "" {
		l.Reg = f.Reg
	}
	if f.TypeCode != "" {
		l.Type = f.TypeCode
	}
	l.LastSeen = max(l.LastSeen, p.T)
	l.MaxAlt = max(l.MaxAlt, p.AltFt)
	l.Source |= source
	dist := -1.0
	if t.cfg.RadiusNM > 0 {
		dist = geo.DistanceNM(t.cfg.CenterLat, t.cfg.CenterLon, f.Lat, f.Lon)
		if l.MinDist < 0 || dist < l.MinDist {
			l.MinDist = math.Round(dist*100) / 100
		}
	}
	ls.dirty = true
	if source == store.SourceArea && dist >= 0 && dist <= t.cfg.RadiusNM && !strings.HasPrefix(f.ID, "~") {
		t.sightLocked(ctx, f, p, dist)
	}
}

// endsLeg decides whether p starts a new leg.
func (t *Tracker) endsLeg(ls *legState, p trackenc.Point) bool {
	if p.T-ls.lastSeen.T > int64(t.cfg.LegGap/time.Second) {
		return true
	}
	if p.T-ls.leg.FirstSeen > int64(t.cfg.MaxLeg/time.Second) {
		return true
	}
	// Took off again after a turnaround on the ground.
	return !p.Ground && ls.wasAirborne && ls.groundSince > 0 && p.T-ls.groundSince >= int64(t.cfg.Turnaround/time.Second)
}

func (t *Tracker) glitch(prev, p trackenc.Point) bool {
	dt := float64(p.T - prev.T)
	d := geo.DistanceNM(prev.Lat, prev.Lon, p.Lat, p.Lon)
	return d > 2 && d/(dt/3600) > t.cfg.MaxImpliedKt
}

// closeLocked ends a leg: its last observed position is stored so the track ends where the
// aircraft was last seen, and it is queued for the next flush.
func (t *Tracker) closeLocked(ls *legState) {
	if !ls.seenStored && ls.lastSeen.T > ls.lastStored.T {
		if b, err := ls.enc.Append(ls.pending, ls.lastSeen); err == nil {
			ls.pending = b
			ls.pendingN++
			ls.lastStored, ls.seenStored = ls.lastSeen, true
			ls.dirty = true
		}
	}
	delete(t.legs, ls.leg.Hex)
	t.closing = append(t.closing, ls)
}

func looksLikeAirline(cs string) bool {
	return len(cs) >= 4 && isLetter(cs[0]) && isLetter(cs[1]) && isLetter(cs[2]) && cs[3] >= '0' && cs[3] <= '9'
}

func isLetter(c byte) bool { return c >= 'A' && c <= 'Z' }

// appendRecent appends v (moving it to the end if present) and keeps the last limit items.
func appendRecent(list []string, v string, limit int) []string {
	if len(list) > 0 && list[len(list)-1] == v {
		return list
	}
	list = slices.DeleteFunc(list, func(s string) bool { return s == v })
	list = append(list, v)
	if len(list) > limit {
		list = list[len(list)-limit:]
	}
	return list
}

func (t *Tracker) sightLocked(ctx context.Context, f *adsb.Flight, p trackenc.Point, dist float64) {
	ss := t.sightings[f.ID]
	if ss == nil {
		ss = &sightingState{}
		if prev, err := t.st.Sighting(ctx, f.ID); err == nil && prev != nil {
			ss.s = *prev
		} else {
			ss.s = store.Sighting{Hex: f.ID, FirstSeen: p.T, LastSeen: p.T, Sightings: 1, ClosestNM: dist, ClosestAt: p.T,
				Callsigns: []string{}, Routes: []string{}}
		}
		t.sightings[f.ID] = ss
	}
	s := &ss.s
	if p.T-s.LastSeen > int64(t.cfg.LegGap/time.Second) {
		s.Sightings++
	}
	s.LastSeen = max(s.LastSeen, p.T)
	if f.Reg != "" && f.Reg != strings.ToUpper(f.ID) {
		s.Registration = f.Reg
	}
	if f.TypeCode != "" {
		s.TypeCode = f.TypeCode
	}
	if f.OwnOp != "" {
		s.OperatorName = f.OwnOp
	}
	if cs := f.Callsign; cs != "" {
		s.Callsigns = appendRecent(s.Callsigns, cs, callsignLimit)
		if looksLikeAirline(cs) {
			s.AirlineICAO = cs[:3]
		}
		if t.routes != nil {
			if o, d, ok := t.routes(cs); ok && o != "" && d != "" {
				s.Routes = appendRecent(s.Routes, o+"-"+d, routeLimit)
			}
		}
	}
	if dist < s.ClosestNM {
		s.ClosestNM, s.ClosestAt = math.Round(dist*100)/100, p.T
	}
	s.MaxAltitude = max(s.MaxAltitude, p.AltFt)
	ss.dirty = true
}

// Flush closes legs unseen for LegGap and writes every pending change in one transaction.
func (t *Tracker) Flush(ctx context.Context, now time.Time) error {
	t.mu.Lock()
	defer t.mu.Unlock()
	gap := int64(t.cfg.LegGap / time.Second)
	for _, ls := range t.legs {
		if now.Unix()-ls.lastSeen.T > gap {
			t.closeLocked(ls)
		}
	}
	var writes []store.LegWrite
	var states []*legState
	collect := func(ls *legState) {
		if !ls.dirty && ls.pendingN == 0 {
			return
		}
		if ls.leg.Origin == "" && ls.leg.Callsign != "" && t.routes != nil {
			if o, d, ok := t.routes(ls.leg.Callsign); ok {
				ls.leg.Origin, ls.leg.Dest = o, d
			}
		}
		writes = append(writes, store.LegWrite{Leg: &ls.leg, Append: ls.pending, AddPoints: ls.pendingN})
		states = append(states, ls)
	}
	for _, ls := range t.legs {
		collect(ls)
	}
	for _, ls := range t.closing {
		collect(ls)
	}
	var sights []*store.Sighting
	var sightStates []*sightingState
	for _, ss := range t.sightings {
		if ss.dirty {
			s := ss.s
			sights = append(sights, &s)
			sightStates = append(sightStates, ss)
		}
	}
	if err := t.st.WriteBatch(ctx, writes, sights); err != nil {
		return err
	}
	for _, ls := range states {
		ls.pending, ls.pendingN, ls.dirty = nil, 0, false
	}
	for _, ss := range sightStates {
		ss.dirty = false
	}
	t.closing = t.closing[:0]
	// Forget sightings not seen for a while; they reload from the database when seen again.
	for hex, ss := range t.sightings {
		if !ss.dirty && now.Unix()-ss.s.LastSeen > 2*gap {
			delete(t.sightings, hex)
		}
	}
	return nil
}

// Track is a leg and its points.
type Track struct {
	Leg    store.Leg
	Points []trackenc.Point
	Active bool
}

// ActiveTrack returns the in-progress leg for hex, including points not yet flushed and the
// latest observed position, or false when the tracker isn't following hex.
func (t *Tracker) ActiveTrack(ctx context.Context, hex string) (Track, bool, error) {
	t.mu.Lock()
	defer t.mu.Unlock()
	ls := t.legs[hex]
	if ls == nil {
		return Track{}, false, nil
	}
	var blob []byte
	if ls.leg.ID != 0 {
		b, err := t.st.TrackBlobWriter(ctx, ls.leg.ID)
		if err != nil {
			return Track{}, false, err
		}
		blob = b
	}
	all := make([]byte, 0, len(blob)+len(ls.pending))
	all = append(append(all, blob...), ls.pending...)
	pts, err := trackenc.Decode(ls.leg.FirstSeen, all)
	if err != nil {
		return Track{}, false, err
	}
	if !ls.seenStored && ls.lastSeen.T > ls.lastStored.T {
		pts = append(pts, trackenc.Quantise(ls.lastSeen))
	}
	leg := ls.leg
	leg.Points += ls.pendingN
	return Track{Leg: leg, Points: pts, Active: true}, true, nil
}

// Stats are tracker counters.
type Stats struct {
	ActiveLegs     int   `json:"activeLegs"`
	PendingPoints  int   `json:"pendingPoints"`
	PointsObserved int64 `json:"pointsObserved"`
	PointsStored   int64 `json:"pointsStored"`
}

// Stats returns counters since start.
func (t *Tracker) Stats() Stats {
	t.mu.Lock()
	defer t.mu.Unlock()
	s := Stats{ActiveLegs: len(t.legs), PointsObserved: t.pointsSeen, PointsStored: t.pointsKept}
	for _, ls := range t.legs {
		s.PendingPoints += ls.pendingN
	}
	return s
}
