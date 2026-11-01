package main

import (
	"context"
	"errors"
	"strings"
	"testing"
	"time"
)

func TestFetchRespectsLockoutWithoutCallingServer(t *testing.T) {
	cached := &Usage{Plan: "max", FetchedAt: time.Now().Add(-time.Hour)}
	until := time.Now().Add(5 * time.Minute)
	// No credentials exist for this dir, so any real fetch would fail with
	// errLoggedOut; getting the cache back proves no request was made.
	a := &Account{Provider: Claude, Dir: t.TempDir(), cached: cached, blockedUntil: until}
	u, err := a.Fetch(context.Background())
	var rl *rateLimitError
	if !errors.As(err, &rl) || !rl.Until.Equal(until) {
		t.Fatalf("err = %v, want rateLimitError until %v", err, until)
	}
	if u != cached {
		t.Errorf("want cached usage during lockout")
	}
}

func TestFetchReusesRecentResult(t *testing.T) {
	cached := &Usage{Plan: "max", FetchedAt: time.Now().Add(-90 * time.Second)} // inside Claude's 2m gap
	a := &Account{Provider: Claude, Dir: t.TempDir(), cached: cached}
	if u, err := a.Fetch(context.Background()); err != nil || u != cached {
		t.Fatalf("got %v, %v; want cached result", u, err)
	}
	a.Invalidate()
	if _, err := a.Fetch(context.Background()); !errors.Is(err, errLoggedOut) {
		t.Fatalf("after Invalidate err = %v, want a real fetch (errLoggedOut)", err)
	}
}

func TestRetryAfter(t *testing.T) {
	if got := retryAfter("300"); got != 5*time.Minute {
		t.Errorf("seconds: got %v", got)
	}
	if got := retryAfter(""); got != time.Minute {
		t.Errorf("missing: got %v", got)
	}
	date := time.Now().Add(2 * time.Minute).UTC().Format("Mon, 02 Jan 2006 15:04:05 GMT")
	if got := retryAfter(date); got < 110*time.Second || got > 2*time.Minute {
		t.Errorf("date: got %v", got)
	}
}

func TestWaitTurnSpacesRequests(t *testing.T) {
	host := "spacing.test"
	start := time.Now()
	for range 3 {
		if err := waitTurn(context.Background(), host); err != nil {
			t.Fatal(err)
		}
	}
	if el := time.Since(start); el < 2*requestSpacing {
		t.Errorf("3 requests took %v, want >= %v", el, 2*requestSpacing)
	}
}

func TestRenderRateLimited(t *testing.T) {
	accounts = testAccounts()
	now := time.Now()
	m := &model{rows: make([]row, len(accounts)), now: now, ivIdx: 2, width: 100}
	m.rows[0] = row{
		usage: &Usage{Plan: "max 20x", Limits: []Limit{{"Weekly", 61, now.Add(28 * time.Hour), true}}, FetchedAt: now},
		err:   &rateLimitError{Until: now.Add(4*time.Minute + 10*time.Second)},
	}
	out := m.View()
	for _, want := range []string{"rate limited", "retrying in 4m", "61%"} {
		if !strings.Contains(out, want) {
			t.Errorf("view missing %q", want)
		}
	}
}
