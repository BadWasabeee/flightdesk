// Package upstream is the server's only way out to the internet. Every request goes through
// Client.Get, which enforces each service's published rate limit (a minimum spacing between
// requests and, where there is one, a daily allowance with a reserve), counts requests per UTC
// day, and pauses a service after a 429 or when its rate-limit headers say it is nearly spent,
// mirroring the apps' ApiBudget.
package upstream

import (
	"context"
	"errors"
	"fmt"
	"io"
	"maps"
	"net/http"
	"slices"
	"strconv"
	"strings"
	"sync"
	"time"
)

// Service identifies an upstream API.
type Service string

const (
	AdsbFi          Service = "adsb.fi"
	AdsbLol         Service = "adsb.lol"
	OpenSky         Service = "opensky"
	Adsbdb          Service = "adsbdb"
	Airframes       Service = "airframes"
	AviationWeather Service = "aviationweather"
)

// Services lists every service, for stats.
var Services = []Service{AdsbFi, AdsbLol, OpenSky, Adsbdb, Airframes, AviationWeather}

// Policy is a service's rate limit.
type Policy struct {
	// MinInterval between requests to the service.
	MinInterval time.Duration
	// DailyLimit per UTC day (0 = none published).
	DailyLimit int
	// Reserve is left unused, so the server never runs a daily allowance dry.
	Reserve int
}

// DefaultPolicies follow each service's published guidance:
//   - adsb.fi open data: 1 request/second per IP.
//   - adsb.lol: 500/day per IP without a key (the apps keep 60 in reserve).
//   - OpenSky anonymous: about 400 requests/day (40 in reserve).
//   - adsbdb: no published limit; be gentle (2/s).
//   - Airframes.io: 60/minute keyless; stay at 40.
//   - aviationweather.gov: asks for under 100/minute; stay at 60.
var DefaultPolicies = map[Service]Policy{
	AdsbFi:          {MinInterval: 1100 * time.Millisecond},
	AdsbLol:         {MinInterval: 2 * time.Second, DailyLimit: 500, Reserve: 60},
	OpenSky:         {MinInterval: 2 * time.Second, DailyLimit: 400, Reserve: 40},
	Adsbdb:          {MinInterval: 500 * time.Millisecond},
	Airframes:       {MinInterval: 1500 * time.Millisecond},
	AviationWeather: {MinInterval: time.Second},
}

var (
	// ErrPaused: the service asked us to slow down (429 or nearly-spent headers).
	ErrPaused = errors.New("upstream paused after a rate-limit response")
	// ErrBudget: today's allowance (minus reserve) is used up.
	ErrBudget = errors.New("upstream daily budget used")
	// ErrBusy: the next free request slot is later than the caller is willing to wait.
	ErrBusy = errors.New("upstream rate limit: no slot before deadline")
)

// Response is a completed upstream response.
type Response struct {
	Status int
	Body   []byte
	Header http.Header
}

// MaxBody caps every upstream response body.
const MaxBody = 8 << 20

type serviceState struct {
	policy      Policy
	next        time.Time // earliest time for the next request
	count       int       // requests today
	errors      int       // transport errors and 5xx today
	pausedUntil time.Time
	lastStatus  int
}

// Client is safe for concurrent use.
type Client struct {
	http *http.Client
	ua   string
	now  func() time.Time

	mu       sync.Mutex
	day      string
	services map[Service]*serviceState
}

// New makes a client. policies may override DefaultPolicies (tests use zero intervals).
func New(userAgent string, timeout time.Duration, policies map[Service]Policy) *Client {
	c := &Client{
		http: &http.Client{
			Timeout: timeout,
			Transport: &http.Transport{
				Proxy:               http.ProxyFromEnvironment,
				MaxIdleConnsPerHost: 4,
				IdleConnTimeout:     90 * time.Second,
				TLSHandshakeTimeout: 10 * time.Second,
				ForceAttemptHTTP2:   true,
			},
			CheckRedirect: func(req *http.Request, via []*http.Request) error {
				if len(via) >= 3 {
					return errors.New("too many redirects")
				}
				return nil
			},
		},
		ua:       userAgent,
		now:      time.Now,
		services: make(map[Service]*serviceState),
	}
	all := maps.Clone(DefaultPolicies)
	maps.Copy(all, policies)
	for s, p := range all {
		c.services[s] = &serviceState{policy: p}
	}
	c.day = c.today()
	return c
}

// SetClock replaces the clock (tests).
func (c *Client) SetClock(now func() time.Time) { c.mu.Lock(); c.now = now; c.mu.Unlock() }

func (c *Client) today() string { return c.now().UTC().Format("2006-01-02") }

func (c *Client) rolloverLocked() {
	if d := c.today(); d != c.day {
		c.day = d
		for _, s := range c.services {
			s.count, s.errors = 0, 0
		}
	}
}

func (c *Client) state(svc Service) *serviceState {
	s, ok := c.services[svc]
	if !ok {
		s = &serviceState{}
		c.services[svc] = s
	}
	return s
}

// Available reports whether svc may be used now (not paused, budget left).
func (c *Client) Available(svc Service) bool {
	c.mu.Lock()
	defer c.mu.Unlock()
	c.rolloverLocked()
	return c.availableLocked(c.state(svc)) == nil
}

func (c *Client) availableLocked(s *serviceState) error {
	if c.now().Before(s.pausedUntil) {
		return ErrPaused
	}
	if s.policy.DailyLimit > 0 && s.count >= s.policy.DailyLimit-s.policy.Reserve {
		return ErrBudget
	}
	return nil
}

// reserve claims the next request slot and returns how long to wait for it.
func (c *Client) reserve(ctx context.Context, svc Service) (time.Duration, error) {
	c.mu.Lock()
	defer c.mu.Unlock()
	c.rolloverLocked()
	s := c.state(svc)
	if err := c.availableLocked(s); err != nil {
		return 0, err
	}
	now := c.now()
	start := s.next
	if start.Before(now) {
		start = now
	}
	wait := start.Sub(now)
	if dl, ok := ctx.Deadline(); ok && now.Add(wait).After(dl) {
		return 0, ErrBusy
	}
	s.next = start.Add(s.policy.MinInterval)
	s.count++
	return wait, nil
}

// Get fetches url from svc, waiting for a rate-limit slot (bounded by ctx's deadline). Any HTTP
// status is returned as a Response; callers decide what counts as success. A 429 pauses the
// service and returns ErrPaused alongside the response.
func (c *Client) Get(ctx context.Context, svc Service, url string) (*Response, error) {
	wait, err := c.reserve(ctx, svc)
	if err != nil {
		return nil, fmt.Errorf("%s: %w", svc, err)
	}
	if wait > 0 {
		t := time.NewTimer(wait)
		select {
		case <-t.C:
		case <-ctx.Done():
			t.Stop()
			return nil, ctx.Err()
		}
	}
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, url, nil)
	if err != nil {
		return nil, err
	}
	req.Header.Set("User-Agent", c.ua)
	req.Header.Set("Accept", "application/json")
	resp, err := c.http.Do(req)
	if err != nil {
		c.noteError(svc, 0)
		return nil, fmt.Errorf("%s: %w", svc, err)
	}
	defer resp.Body.Close()
	body, err := io.ReadAll(io.LimitReader(resp.Body, MaxBody+1))
	if err != nil {
		c.noteError(svc, resp.StatusCode)
		return nil, fmt.Errorf("%s: reading body: %w", svc, err)
	}
	if len(body) > MaxBody {
		return nil, fmt.Errorf("%s: response larger than %d bytes", svc, MaxBody)
	}
	out := &Response{Status: resp.StatusCode, Body: body, Header: resp.Header}
	c.noteResponse(svc, out)
	if resp.StatusCode == http.StatusTooManyRequests {
		return out, fmt.Errorf("%s: HTTP 429: %w", svc, ErrPaused)
	}
	return out, nil
}

func (c *Client) noteError(svc Service, status int) {
	c.mu.Lock()
	defer c.mu.Unlock()
	s := c.state(svc)
	s.errors++
	s.lastStatus = status
}

func (c *Client) noteResponse(svc Service, r *Response) {
	c.mu.Lock()
	defer c.mu.Unlock()
	s := c.state(svc)
	s.lastStatus = r.Status
	if r.Status >= 500 {
		s.errors++
	}
	if d, ok := PauseFor(s.policy, r.Status, r.Header, c.now()); ok {
		if until := c.now().Add(d); until.After(s.pausedUntil) {
			s.pausedUntil = until
		}
	}
}

// PauseFor is how long to stop using a service after a response, from its status and rate-limit
// headers (the same rules as the apps' ApiBudget.pauseInterval): adsb.lol and Airframes send
// x-ratelimit-remaining/-reset (Airframes' reset is a Unix time), OpenSky sends
// X-Rate-Limit-Remaining and X-Rate-Limit-Retry-After-Seconds.
func PauseFor(p Policy, status int, h http.Header, now time.Time) (time.Duration, bool) {
	num := func(name string) (float64, bool) {
		v := h.Get(name)
		if v == "" {
			return 0, false
		}
		// "500, 500;w=86400": take the leading number.
		end := strings.IndexFunc(v, func(r rune) bool { return !(r >= '0' && r <= '9' || r == '.') })
		if end == 0 {
			return 0, false
		}
		if end > 0 {
			v = v[:end]
		}
		f, err := strconv.ParseFloat(v, 64)
		return f, err == nil
	}
	var retry time.Duration
	haveRetry := false
	if r, ok := num("X-Rate-Limit-Retry-After-Seconds"); ok {
		retry, haveRetry = time.Duration(r*float64(time.Second)), true
	} else if r, ok := num("Retry-After"); ok {
		retry, haveRetry = time.Duration(r*float64(time.Second)), true
	} else if r, ok := num("X-Ratelimit-Reset"); ok {
		if r > 1e9 { // a Unix time, not seconds
			r = max(0, r-float64(now.Unix()))
		}
		retry, haveRetry = time.Duration(r*float64(time.Second)), true
	}
	if status == http.StatusTooManyRequests {
		if haveRetry {
			return max(retry, 5*time.Second), true
		}
		return 30 * time.Minute, true
	}
	rem, ok := num("X-Ratelimit-Remaining")
	if !ok {
		rem, ok = num("X-Rate-Limit-Remaining")
	}
	if ok && p.Reserve > 0 && int(rem) <= p.Reserve {
		if haveRetry {
			return retry, true
		}
		return time.Hour, true
	}
	return 0, false
}

// ServiceStats is one service's counters for today.
type ServiceStats struct {
	Requests    int        `json:"requests"`
	Errors      int        `json:"errors"`
	DailyLimit  int        `json:"dailyLimit,omitempty"`
	Reserve     int        `json:"reserve,omitempty"`
	PausedUntil *time.Time `json:"pausedUntil,omitempty"`
	LastStatus  int        `json:"lastStatus,omitempty"`
}

// Stats returns today's counters.
func (c *Client) Stats() (day string, out map[Service]ServiceStats) {
	c.mu.Lock()
	defer c.mu.Unlock()
	c.rolloverLocked()
	out = make(map[Service]ServiceStats, len(c.services))
	for svc, s := range c.services {
		st := ServiceStats{Requests: s.count, Errors: s.errors, DailyLimit: s.policy.DailyLimit, Reserve: s.policy.Reserve, LastStatus: s.lastStatus}
		if c.now().Before(s.pausedUntil) {
			t := s.pausedUntil.UTC()
			st.PausedUntil = &t
		}
		out[svc] = st
	}
	return c.day, out
}

// Counts returns today's request counts (for persistence across restarts).
func (c *Client) Counts() (day string, counts map[string]int) {
	c.mu.Lock()
	defer c.mu.Unlock()
	c.rolloverLocked()
	counts = make(map[string]int)
	for _, svc := range slices.Sorted(maps.Keys(c.services)) {
		counts[string(svc)] = c.services[svc].count
	}
	return c.day, counts
}

// Restore re-applies counts saved earlier today, so a restart can't reset daily allowances.
func (c *Client) Restore(day string, counts map[string]int) {
	c.mu.Lock()
	defer c.mu.Unlock()
	c.rolloverLocked()
	if day != c.day {
		return
	}
	for svc, n := range counts {
		s := c.state(Service(svc))
		s.count = max(s.count, n)
	}
}
