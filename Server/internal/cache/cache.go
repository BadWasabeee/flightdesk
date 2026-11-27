// Package cache is a small in-memory TTL cache with request coalescing: concurrent callers asking
// for the same missing key share one upstream fetch, and a stale value is served when a refresh
// fails.
package cache

import (
	"context"
	"sync"
	"time"
)

// Value is a cached upstream answer.
type Value struct {
	Status  int
	Body    []byte
	Fetched time.Time
}

// Result says where a value came from.
type Result int

const (
	Hit     Result = iota // fresh cached value
	Fetched               // fetched by this or a coalesced call
	Stale                 // refresh failed; an expired value was served
)

func (r Result) String() string {
	switch r {
	case Hit:
		return "hit"
	case Fetched:
		return "miss"
	default:
		return "stale"
	}
}

// FetchFunc fetches a value and says how long it stays fresh (0 = don't cache).
type FetchFunc func(ctx context.Context) (Value, time.Duration, error)

type item struct {
	v          Value
	freshUntil time.Time
	staleUntil time.Time
}

type call struct {
	done chan struct{}
	v    Value
	err  error
}

// Group is the cache. The zero value is not usable; use New.
type Group struct {
	mu       sync.Mutex
	items    map[string]*item
	calls    map[string]*call
	maxItems int
	staleFor time.Duration
	timeout  time.Duration
	now      func() time.Time

	fetches int // upstream fetches started, for tests and stats
}

// New makes a cache holding at most maxItems values; expired values may be served for staleFor
// after a failed refresh. Each fetch gets timeout, independent of the callers' contexts, so one
// impatient client can't cancel a fetch others are waiting for.
func New(maxItems int, staleFor, timeout time.Duration) *Group {
	return &Group{
		items:    make(map[string]*item),
		calls:    make(map[string]*call),
		maxItems: maxItems,
		staleFor: staleFor,
		timeout:  timeout,
		now:      time.Now,
	}
}

// SetClock replaces the clock (tests).
func (g *Group) SetClock(now func() time.Time) { g.mu.Lock(); g.now = now; g.mu.Unlock() }

// Fetches is the number of upstream fetches started.
func (g *Group) Fetches() int { g.mu.Lock(); defer g.mu.Unlock(); return g.fetches }

// Len is the number of cached values.
func (g *Group) Len() int { g.mu.Lock(); defer g.mu.Unlock(); return len(g.items) }

// Peek returns a cached value without fetching, fresh or not.
func (g *Group) Peek(key string) (Value, bool) {
	g.mu.Lock()
	defer g.mu.Unlock()
	if it, ok := g.items[key]; ok {
		return it.v, true
	}
	return Value{}, false
}

// Get returns the fresh value for key, or fetches it once for all concurrent callers.
func (g *Group) Get(ctx context.Context, key string, fetch FetchFunc) (Value, Result, error) {
	g.mu.Lock()
	now := g.now()
	if it, ok := g.items[key]; ok && now.Before(it.freshUntil) {
		g.mu.Unlock()
		return it.v, Hit, nil
	}
	c, running := g.calls[key]
	if !running {
		c = &call{done: make(chan struct{})}
		g.calls[key] = c
		g.fetches++
		go g.run(ctx, key, c, fetch)
	}
	g.mu.Unlock()

	select {
	case <-c.done:
	case <-ctx.Done():
		return Value{}, Fetched, ctx.Err()
	}
	if c.err == nil {
		return c.v, Fetched, nil
	}
	g.mu.Lock()
	defer g.mu.Unlock()
	if it, ok := g.items[key]; ok && g.now().Before(it.staleUntil) {
		return it.v, Stale, nil
	}
	return Value{}, Fetched, c.err
}

func (g *Group) run(parent context.Context, key string, c *call, fetch FetchFunc) {
	ctx, cancel := context.WithTimeout(context.WithoutCancel(parent), g.timeout)
	defer cancel()
	v, ttl, err := fetch(ctx)
	g.mu.Lock()
	defer g.mu.Unlock()
	delete(g.calls, key)
	c.v, c.err = v, err
	if err == nil && ttl > 0 {
		now := g.now()
		if v.Fetched.IsZero() {
			v.Fetched = now
			c.v.Fetched = now
		}
		g.items[key] = &item{v: v, freshUntil: now.Add(ttl), staleUntil: now.Add(ttl + g.staleFor)}
		g.evictLocked(now)
	}
	close(c.done)
}

// Put stores a value directly.
func (g *Group) Put(key string, v Value, ttl time.Duration) {
	g.mu.Lock()
	defer g.mu.Unlock()
	now := g.now()
	if v.Fetched.IsZero() {
		v.Fetched = now
	}
	g.items[key] = &item{v: v, freshUntil: now.Add(ttl), staleUntil: now.Add(ttl + g.staleFor)}
	g.evictLocked(now)
}

func (g *Group) evictLocked(now time.Time) {
	if len(g.items) <= g.maxItems {
		return
	}
	for k, it := range g.items {
		if now.After(it.staleUntil) {
			delete(g.items, k)
		}
	}
	// Still full: drop the values closest to expiry until a tenth of the room is free.
	for len(g.items) > g.maxItems*9/10 {
		var victim string
		var soonest time.Time
		for k, it := range g.items {
			if victim == "" || it.staleUntil.Before(soonest) {
				victim, soonest = k, it.staleUntil
			}
		}
		delete(g.items, victim)
	}
}

// Sweep removes values past their stale window; call it periodically.
func (g *Group) Sweep() {
	g.mu.Lock()
	defer g.mu.Unlock()
	now := g.now()
	for k, it := range g.items {
		if now.After(it.staleUntil) {
			delete(g.items, k)
		}
	}
}
