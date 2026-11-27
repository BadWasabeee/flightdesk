package cache

import (
	"context"
	"errors"
	"sync"
	"sync/atomic"
	"testing"
	"time"
)

func TestCoalescesConcurrentMisses(t *testing.T) {
	g := New(100, time.Minute, 5*time.Second)
	var calls atomic.Int32
	release := make(chan struct{})
	fetch := func(ctx context.Context) (Value, time.Duration, error) {
		calls.Add(1)
		<-release
		return Value{Status: 200, Body: []byte("x")}, time.Minute, nil
	}
	var wg sync.WaitGroup
	results := make([]Value, 50)
	for i := range results {
		wg.Add(1)
		go func() {
			defer wg.Done()
			v, _, err := g.Get(context.Background(), "k", fetch)
			if err != nil {
				t.Error(err)
			}
			results[i] = v
		}()
	}
	// Let every goroutine reach the wait before releasing the single fetch.
	for g.Fetches() == 0 {
		time.Sleep(time.Millisecond)
	}
	time.Sleep(20 * time.Millisecond)
	close(release)
	wg.Wait()
	if n := calls.Load(); n != 1 {
		t.Fatalf("%d upstream fetches, want 1", n)
	}
	for _, v := range results {
		if string(v.Body) != "x" {
			t.Fatal("caller got wrong value")
		}
	}
	// A later call is a cache hit.
	if _, res, _ := g.Get(context.Background(), "k", fetch); res != Hit {
		t.Fatalf("got %v, want hit", res)
	}
}

func TestStaleServedOnFailure(t *testing.T) {
	now := time.Unix(1000, 0)
	g := New(100, time.Minute, time.Second)
	g.SetClock(func() time.Time { return now })
	ok := func(context.Context) (Value, time.Duration, error) {
		return Value{Status: 200, Body: []byte("old")}, 5 * time.Second, nil
	}
	fail := func(context.Context) (Value, time.Duration, error) { return Value{}, 0, errors.New("down") }
	if _, _, err := g.Get(context.Background(), "k", ok); err != nil {
		t.Fatal(err)
	}
	now = now.Add(10 * time.Second) // expired, within the stale window
	v, res, err := g.Get(context.Background(), "k", fail)
	if err != nil || res != Stale || string(v.Body) != "old" {
		t.Fatalf("got %q %v %v", v.Body, res, err)
	}
	now = now.Add(2 * time.Minute) // past the stale window
	if _, _, err := g.Get(context.Background(), "k", fail); err == nil {
		t.Fatal("expected error past stale window")
	}
}

func TestCallerCancelDoesNotCancelSharedFetch(t *testing.T) {
	g := New(100, 0, 5*time.Second)
	release := make(chan struct{})
	var fetchErr atomic.Value
	fetch := func(ctx context.Context) (Value, time.Duration, error) {
		select {
		case <-release:
		case <-ctx.Done():
			fetchErr.Store(ctx.Err())
			return Value{}, 0, ctx.Err()
		}
		return Value{Body: []byte("v")}, time.Minute, nil
	}
	ctx, cancel := context.WithCancel(context.Background())
	done := make(chan struct{})
	go func() {
		defer close(done)
		if _, _, err := g.Get(ctx, "k", fetch); !errors.Is(err, context.Canceled) {
			t.Errorf("got %v", err)
		}
	}()
	for g.Fetches() == 0 {
		time.Sleep(time.Millisecond)
	}
	cancel()
	<-done
	close(release)
	// The fetch completes and is cached for the next caller.
	deadline := time.Now().Add(time.Second)
	for g.Len() == 0 && time.Now().Before(deadline) {
		time.Sleep(time.Millisecond)
	}
	if fetchErr.Load() != nil {
		t.Fatal("shared fetch was cancelled by one caller")
	}
	if v, res, _ := g.Get(context.Background(), "k", fetch); res != Hit || string(v.Body) != "v" {
		t.Fatalf("got %v", res)
	}
}

func TestEvictionBounded(t *testing.T) {
	g := New(10, 0, time.Second)
	for i := range 100 {
		g.Put(string(rune('a'+i)), Value{}, time.Duration(i+1)*time.Second)
	}
	if g.Len() > 10 {
		t.Fatalf("len %d", g.Len())
	}
}
