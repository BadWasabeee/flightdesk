package upstream

import (
	"context"
	"errors"
	"net/http"
	"net/http/httptest"
	"strconv"
	"testing"
	"time"
)

func TestMinIntervalSpacesRequests(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) { w.Write([]byte("{}")) }))
	defer srv.Close()
	c := New("test", 5*time.Second, map[Service]Policy{AdsbFi: {MinInterval: 50 * time.Millisecond}})
	start := time.Now()
	for range 4 {
		if _, err := c.Get(context.Background(), AdsbFi, srv.URL); err != nil {
			t.Fatal(err)
		}
	}
	if el := time.Since(start); el < 150*time.Millisecond {
		t.Fatalf("4 requests took %v; want >= 150ms spacing", el)
	}
	if _, st := c.Stats(); st[AdsbFi].Requests != 4 {
		t.Fatalf("count %d", st[AdsbFi].Requests)
	}
}

func TestBusyWhenSlotPastDeadline(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {}))
	defer srv.Close()
	c := New("test", time.Second, map[Service]Policy{AdsbFi: {MinInterval: time.Hour}})
	if _, err := c.Get(context.Background(), AdsbFi, srv.URL); err != nil {
		t.Fatal(err)
	}
	ctx, cancel := context.WithTimeout(context.Background(), 50*time.Millisecond)
	defer cancel()
	if _, err := c.Get(ctx, AdsbFi, srv.URL); !errors.Is(err, ErrBusy) {
		t.Fatalf("got %v", err)
	}
}

func TestDailyBudgetWithReserve(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {}))
	defer srv.Close()
	c := New("test", time.Second, map[Service]Policy{OpenSky: {DailyLimit: 5, Reserve: 2}})
	for i := range 3 {
		if _, err := c.Get(context.Background(), OpenSky, srv.URL); err != nil {
			t.Fatalf("request %d: %v", i, err)
		}
	}
	if _, err := c.Get(context.Background(), OpenSky, srv.URL); !errors.Is(err, ErrBudget) {
		t.Fatalf("got %v, want budget error", err)
	}
	// A new UTC day resets the allowance.
	c.SetClock(func() time.Time { return time.Now().Add(25 * time.Hour) })
	if _, err := c.Get(context.Background(), OpenSky, srv.URL); err != nil {
		t.Fatal(err)
	}
}

func TestRestoreCountsSameDayOnly(t *testing.T) {
	c := New("test", time.Second, nil)
	day, _ := c.Counts()
	c.Restore(day, map[string]int{"opensky": 360})
	if c.Available(OpenSky) {
		t.Fatal("restored count not applied")
	}
	c2 := New("test", time.Second, nil)
	c2.Restore("2000-01-01", map[string]int{"opensky": 360})
	if !c2.Available(OpenSky) {
		t.Fatal("old day's counts applied")
	}
}

func Test429PausesService(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Retry-After", "120")
		w.WriteHeader(http.StatusTooManyRequests)
	}))
	defer srv.Close()
	c := New("test", time.Second, map[Service]Policy{Airframes: {}})
	if _, err := c.Get(context.Background(), Airframes, srv.URL); !errors.Is(err, ErrPaused) {
		t.Fatalf("got %v", err)
	}
	if c.Available(Airframes) {
		t.Fatal("still available after 429")
	}
	if _, err := c.Get(context.Background(), Airframes, srv.URL); !errors.Is(err, ErrPaused) {
		t.Fatalf("second call: %v", err)
	}
}

func TestPauseForHeaders(t *testing.T) {
	now := time.Unix(2_000_000_000, 0)
	h := func(kv ...string) http.Header {
		out := http.Header{}
		for i := 0; i < len(kv); i += 2 {
			out.Set(kv[i], kv[i+1])
		}
		return out
	}
	cases := []struct {
		name   string
		policy Policy
		status int
		h      http.Header
		want   time.Duration
		ok     bool
	}{
		{"429 no headers", Policy{}, 429, h(), 30 * time.Minute, true},
		{"429 opensky retry", Policy{}, 429, h("X-Rate-Limit-Retry-After-Seconds", "600"), 10 * time.Minute, true},
		{"airframes unix reset", Policy{}, 429, h("X-Ratelimit-Reset", strconv.FormatInt(now.Unix()+90, 10)), 90 * time.Second, true},
		{"lol remaining at reserve", Policy{Reserve: 60}, 200, h("X-Ratelimit-Remaining", "60, 500;w=86400", "X-Ratelimit-Reset", "300"), 5 * time.Minute, true},
		{"lol remaining above reserve", Policy{Reserve: 60}, 200, h("X-Ratelimit-Remaining", "61"), 0, false},
		{"opensky remaining no retry", Policy{Reserve: 40}, 200, h("X-Rate-Limit-Remaining", "10"), time.Hour, true},
		{"no reserve ignores remaining", Policy{}, 200, h("X-Ratelimit-Remaining", "0"), 0, false},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			got, ok := PauseFor(c.policy, c.status, c.h, now)
			if ok != c.ok || got != c.want {
				t.Fatalf("got %v %v, want %v %v", got, ok, c.want, c.ok)
			}
		})
	}
}

func TestBodyCapAndUserAgent(t *testing.T) {
	var ua string
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		ua = r.Header.Get("User-Agent")
		w.Write(make([]byte, MaxBody+10))
	}))
	defer srv.Close()
	c := New("FlightDesk-Server/test", 5*time.Second, map[Service]Policy{Adsbdb: {}})
	if _, err := c.Get(context.Background(), Adsbdb, srv.URL); err == nil {
		t.Fatal("oversized body accepted")
	}
	if ua != "FlightDesk-Server/test" {
		t.Fatalf("UA %q", ua)
	}
}
