// Package poller runs the area poller and the per-flight watches, and owns the live feeds
// (adsb.fi first, adsb.lol as a budgeted fallback).
package poller

import (
	"context"
	"errors"
	"fmt"
	"strings"
	"sync"
	"time"

	"github.com/BadWasabeee/flightdesk/Server/internal/adsb"
	"github.com/BadWasabeee/flightdesk/Server/internal/upstream"
)

// MaxRadiusNM is the largest radius adsb.fi and adsb.lol accept (adsb.fi answers 400 above it,
// checked against the live API), so an area of up to 250 nm is one request: no tiling needed.
const MaxRadiusNM = 250

// Feeds fetches live aircraft with fallback.
type Feeds struct {
	c  *upstream.Client
	ep upstream.Endpoints
	// LolMinInterval spaces fallback requests: adsb.lol allows only 500 a day.
	LolMinInterval time.Duration

	mu      sync.Mutex
	benched map[upstream.Service]time.Time
	lastLol time.Time
	now     func() time.Time
}

// NewFeeds makes the feed client.
func NewFeeds(c *upstream.Client, ep upstream.Endpoints) *Feeds {
	return &Feeds{c: c, ep: ep, LolMinInterval: 90 * time.Second, benched: map[upstream.Service]time.Time{}, now: time.Now}
}

// ErrNoFeed means no feed could be used right now.
var ErrNoFeed = errors.New("no live feed available")

func (f *Feeds) isBenched(s upstream.Service) bool {
	f.mu.Lock()
	defer f.mu.Unlock()
	return f.now().Before(f.benched[s])
}

func (f *Feeds) bench(s upstream.Service, d time.Duration) {
	f.mu.Lock()
	f.benched[s] = f.now().Add(d)
	f.mu.Unlock()
}

// takeLolSlot claims a fallback slot if the spacing allows.
func (f *Feeds) takeLolSlot() bool {
	f.mu.Lock()
	defer f.mu.Unlock()
	if f.now().Sub(f.lastLol) < f.LolMinInterval {
		return false
	}
	f.lastLol = f.now()
	return true
}

func (f *Feeds) get(ctx context.Context, svc upstream.Service, url string) (*adsb.Response, error) {
	resp, err := f.c.Get(ctx, svc, url)
	if err != nil {
		if errors.Is(err, upstream.ErrPaused) {
			f.bench(svc, 30*time.Minute)
		} else if !errors.Is(err, upstream.ErrBusy) && !errors.Is(err, upstream.ErrBudget) && ctx.Err() == nil {
			f.bench(svc, time.Minute)
		}
		return nil, err
	}
	if resp.Status != 200 {
		f.bench(svc, time.Minute)
		return nil, fmt.Errorf("%s: HTTP %d", svc, resp.Status)
	}
	r, err := adsb.Parse(resp.Body)
	if err != nil {
		f.bench(svc, time.Minute)
		return nil, fmt.Errorf("%s: %w", svc, err)
	}
	return r, nil
}

// Point fetches aircraft within nm of (lat, lon): adsb.fi, else adsb.lol at most every
// LolMinInterval and only while its daily budget lasts. decimals is the coordinate precision
// sent upstream (2 ≈ 1 km for device requests, as the apps do).
func (f *Feeds) Point(ctx context.Context, lat, lon float64, nm, decimals int) (*adsb.Response, upstream.Service, error) {
	if nm < 1 || nm > MaxRadiusNM {
		return nil, "", fmt.Errorf("radius %d out of range", nm)
	}
	la := strings.TrimRight(strings.TrimRight(fmt.Sprintf("%.*f", decimals, lat), "0"), ".")
	lo := strings.TrimRight(strings.TrimRight(fmt.Sprintf("%.*f", decimals, lon), "0"), ".")
	if la == "" || la == "-" {
		la = "0"
	}
	if lo == "" || lo == "-" {
		lo = "0"
	}
	var errs []error
	if !f.isBenched(upstream.AdsbFi) {
		r, err := f.get(ctx, upstream.AdsbFi, fmt.Sprintf("%s/v2/lat/%s/lon/%s/dist/%d", f.ep.AdsbFi, la, lo, nm))
		if err == nil {
			return r, upstream.AdsbFi, nil
		}
		errs = append(errs, err)
	}
	if !f.isBenched(upstream.AdsbLol) && f.c.Available(upstream.AdsbLol) && f.takeLolSlot() {
		r, err := f.get(ctx, upstream.AdsbLol, fmt.Sprintf("%s/v2/point/%s/%s/%d", f.ep.AdsbLol, la, lo, nm))
		if err == nil {
			return r, upstream.AdsbLol, nil
		}
		errs = append(errs, err)
	}
	if len(errs) == 0 {
		return nil, "", ErrNoFeed
	}
	return nil, "", errors.Join(errs...)
}

// Hexes fetches specific aircraft in one adsb.fi request (it accepts a comma-separated list).
// adsb.lol is not used here: watches are low priority and its allowance is small.
func (f *Feeds) Hexes(ctx context.Context, hexes []string) (*adsb.Response, error) {
	if len(hexes) == 0 {
		return &adsb.Response{}, nil
	}
	if f.isBenched(upstream.AdsbFi) {
		return nil, ErrNoFeed
	}
	return f.get(ctx, upstream.AdsbFi, f.ep.AdsbFi+"/v2/hex/"+strings.Join(hexes, ","))
}
