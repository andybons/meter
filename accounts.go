package main

import (
	"context"
	"errors"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"sync"
	"time"
)

type Provider int

const (
	Claude Provider = iota
	Codex
)

func (p Provider) String() string {
	if p == Codex {
		return "Codex"
	}
	return "Claude"
}

// Account is one login, isolated by its own config dir.
type Account struct {
	Provider Provider
	Email    string
	// Dir is the absolute CLAUDE_CONFIG_DIR / CODEX_HOME. Empty means the
	// provider's stock dir (~/.claude or ~/.codex) with the variable unset.
	Dir string

	mu           sync.Mutex // serializes fetch+refresh so two refreshes never race
	cached       *Usage
	blockedUntil time.Time // set from Retry-After on HTTP 429
}

// accounts is loaded from the config file at startup.
var accounts []*Account

func home() string { h, _ := os.UserHomeDir(); return h }

// envDir is the value for CLAUDE_CONFIG_DIR / CODEX_HOME, or "" for default.
func (a *Account) envDir() string { return a.Dir }

// dataDir is where the account's files live, default or not.
func (a *Account) dataDir() string {
	if a.Dir != "" {
		return a.Dir
	}
	if a.Provider == Codex {
		return filepath.Join(home(), ".codex")
	}
	return filepath.Join(home(), ".claude")
}

func (a *Account) envVar() string {
	if a.Provider == Codex {
		return "CODEX_HOME"
	}
	return "CLAUDE_CONFIG_DIR"
}

// Env is the environment for running the provider's CLI as this account.
// API keys are stripped so login and usage go through the subscription.
func (a *Account) Env() []string {
	drop := []string{"CLAUDE_CONFIG_DIR=", "CODEX_HOME=", "ANTHROPIC_API_KEY=", "OPENAI_API_KEY="}
	var env []string
outer:
	for _, kv := range os.Environ() {
		for _, p := range drop {
			if strings.HasPrefix(kv, p) {
				continue outer
			}
		}
		env = append(env, kv)
	}
	if d := a.envDir(); d != "" {
		env = append(env, a.envVar()+"="+d)
	}
	return env
}

// LoginCmd returns the interactive login command for this account.
func (a *Account) LoginCmd() *exec.Cmd {
	var c *exec.Cmd
	if a.Provider == Codex {
		// Force file storage so the dashboard can read auth.json.
		c = exec.Command("codex", "login", "-c", `cli_auth_credentials_store="file"`)
	} else {
		c = exec.Command("claude", "auth", "login")
	}
	c.Env = a.Env()
	return c
}

// Limit is one rate-limit window.
type Limit struct {
	Label    string
	Percent  float64
	ResetsAt time.Time
	Active   bool
}

type Usage struct {
	Plan      string
	Limits    []Limit
	FetchedAt time.Time
}

// errLoggedOut means there are no usable credentials: none stored, or the
// refresh token was rejected. The fix is to log in again.
var errLoggedOut = errors.New("logged out")

// errUnauthorized is returned by usage fetchers on HTTP 401.
var errUnauthorized = errors.New("unauthorized")

// minFetchGap is the shortest time between real requests for one account;
// refreshes inside it reuse the last result. The Claude usage endpoint
// allows only about five calls per token every five minutes (and running
// Claude Code sessions share that budget), so spacing requests apart within
// one refresh doesn't help: each account has to be asked less often.
func (a *Account) minFetchGap() time.Duration {
	if a.Provider == Claude {
		return 2 * time.Minute
	}
	return 30 * time.Second
}

// Fetch returns usage, refreshing the access token first if it has expired
// or the server rejects it. Refreshed tokens are saved back so the CLI
// picks them up too. While the account is rate limited, or if it was
// fetched less than minFetchGap ago, it returns the last result instead of
// calling the server. A rate-limited fetch returns the stale usage along
// with a *rateLimitError.
func (a *Account) Fetch(ctx context.Context) (*Usage, error) {
	a.mu.Lock()
	defer a.mu.Unlock()
	now := time.Now()
	if now.Before(a.blockedUntil) {
		return a.cached, &rateLimitError{Until: a.blockedUntil}
	}
	if a.cached != nil && now.Sub(a.cached.FetchedAt) < a.minFetchGap() {
		return a.cached, nil
	}
	var u *Usage
	var err error
	if a.Provider == Codex {
		u, err = fetchCodex(ctx, a)
	} else {
		u, err = fetchClaude(ctx, a)
	}
	var rl *rateLimitError
	switch {
	case errors.As(err, &rl):
		a.blockedUntil = rl.Until
		return a.cached, err
	case err != nil:
		return nil, err
	}
	u.FetchedAt = now
	a.cached = u
	return u, nil
}

// Invalidate drops the cached result so the next Fetch hits the server
// (unless the account is rate limited). Used after logging in.
func (a *Account) Invalidate() {
	a.mu.Lock()
	a.cached = nil
	a.mu.Unlock()
}

func tokenExpired(exp time.Time) bool {
	return !exp.IsZero() && time.Until(exp) < time.Minute
}
