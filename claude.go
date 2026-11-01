package main

import (
	"bytes"
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"strconv"
	"strings"
	"sync"
	"time"
)

// Values from the installed Claude Code binary.
const (
	claudeTokenURL = "https://platform.claude.com/v1/oauth/token"
	claudeClientID = "9d1c250a-e61b-44d9-88ed-5944d1962f5e"
	claudeUsageURL = "https://api.anthropic.com/api/oauth/usage"
)

// keychainService mirrors Claude Code's naming: a custom config dir gets a
// suffix of the first 8 hex chars of sha256(dir).
func (a *Account) keychainService() string {
	const base = "Claude Code-credentials"
	dir := a.envDir()
	if dir == "" {
		return base
	}
	sum := sha256.Sum256([]byte(dir))
	return base + "-" + hex.EncodeToString(sum[:])[:8]
}

// claudeStore reads and writes the raw credentials blob. The blob is kept as
// a generic map so fields this tool doesn't know about survive a write.
type claudeStore struct {
	a    *Account
	file string // non-empty when using .credentials.json instead of Keychain
}

func (s *claudeStore) read(ctx context.Context) (map[string]any, error) {
	var raw []byte
	if runtime.GOOS == "darwin" {
		out, err := exec.CommandContext(ctx, "security", "find-generic-password",
			"-s", s.a.keychainService(), "-w").Output()
		if err == nil {
			raw = out
		}
	}
	if raw == nil {
		s.file = filepath.Join(s.a.dataDir(), ".credentials.json")
		b, err := os.ReadFile(s.file)
		if err != nil {
			return nil, errLoggedOut
		}
		raw = b
	}
	var blob map[string]any
	if err := json.Unmarshal(raw, &blob); err != nil {
		return nil, fmt.Errorf("parse credentials: %w", err)
	}
	return blob, nil
}

func (s *claudeStore) write(ctx context.Context, blob map[string]any) error {
	b, err := json.Marshal(blob)
	if err != nil {
		return err
	}
	if s.file != "" {
		return writeFileAtomic(s.file, b)
	}
	// -X takes hex, which avoids any quoting issues; -U updates in place.
	return exec.CommandContext(ctx, "security", "add-generic-password", "-U",
		"-a", os.Getenv("USER"), "-s", s.a.keychainService(), "-X", hex.EncodeToString(b)).Run()
}

func oauthSection(blob map[string]any) map[string]any {
	m, _ := blob["claudeAiOauth"].(map[string]any)
	return m
}

func str(m map[string]any, k string) string { s, _ := m[k].(string); return s }

func fetchClaude(ctx context.Context, a *Account) (*Usage, error) {
	store := &claudeStore{a: a}
	blob, err := store.read(ctx)
	if err != nil {
		return nil, err
	}
	o := oauthSection(blob)
	if o == nil || str(o, "accessToken") == "" {
		return nil, errLoggedOut
	}
	exp, _ := o["expiresAt"].(float64)
	if tokenExpired(time.UnixMilli(int64(exp))) {
		if err := refreshClaude(ctx, store, blob); err != nil {
			return nil, err
		}
	}
	u, err := claudeUsage(ctx, str(o, "accessToken"))
	if errors.Is(err, errUnauthorized) {
		if err := refreshClaude(ctx, store, blob); err != nil {
			return nil, err
		}
		u, err = claudeUsage(ctx, str(o, "accessToken"))
	}
	if err != nil {
		return nil, err
	}
	u.Plan = claudePlan(o)
	return u, nil
}

// refreshClaude exchanges the refresh token and saves the result. It updates
// blob (and so the oauth section) in place.
func refreshClaude(ctx context.Context, store *claudeStore, blob map[string]any) error {
	o := oauthSection(blob)
	rt := str(o, "refreshToken")
	if rt == "" {
		return errLoggedOut
	}
	var tok struct {
		AccessToken  string `json:"access_token"`
		RefreshToken string `json:"refresh_token"`
		ExpiresIn    int64  `json:"expires_in"`
	}
	err := postJSON(ctx, claudeTokenURL, map[string]string{
		"grant_type":    "refresh_token",
		"refresh_token": rt,
		"client_id":     claudeClientID,
	}, nil, &tok)
	if err != nil {
		// Claude Code may have rotated the token while we were working;
		// if the stored creds changed, use them instead of logging out.
		if fresh, rerr := store.read(ctx); rerr == nil {
			if fo := oauthSection(fresh); fo != nil && str(fo, "refreshToken") != rt {
				blob["claudeAiOauth"] = fo
				return nil
			}
		}
		return err
	}
	o["accessToken"] = tok.AccessToken
	if tok.RefreshToken != "" {
		o["refreshToken"] = tok.RefreshToken
	}
	if tok.ExpiresIn > 0 {
		o["expiresAt"] = float64(time.Now().Add(time.Duration(tok.ExpiresIn) * time.Second).UnixMilli())
	}
	if err := store.write(ctx, blob); err != nil {
		return fmt.Errorf("save refreshed token: %w", err)
	}
	return nil
}

func claudeUsage(ctx context.Context, token string) (*Usage, error) {
	var r struct {
		Limits []struct {
			Kind     string    `json:"kind"`
			Group    string    `json:"group"`
			Percent  float64   `json:"percent"`
			ResetsAt time.Time `json:"resets_at"`
			IsActive bool      `json:"is_active"`
			Scope    *struct {
				Model *struct {
					DisplayName string `json:"display_name"`
				} `json:"model"`
			} `json:"scope"`
		} `json:"limits"`
		FiveHour *claudeWindow `json:"five_hour"`
		SevenDay *claudeWindow `json:"seven_day"`
	}
	err := getJSON(ctx, claudeUsageURL, map[string]string{
		"Authorization":  "Bearer " + token,
		"anthropic-beta": "oauth-2025-04-20",
	}, &r)
	if err != nil {
		return nil, err
	}
	u := &Usage{}
	for _, l := range r.Limits {
		label := claudeLabel(l.Kind, l.Group)
		if l.Scope != nil && l.Scope.Model != nil && l.Scope.Model.DisplayName != "" {
			label = "Weekly · " + l.Scope.Model.DisplayName
		}
		u.Limits = append(u.Limits, Limit{label, l.Percent, l.ResetsAt, l.IsActive})
	}
	if len(u.Limits) == 0 {
		if w := r.FiveHour; w != nil {
			u.Limits = append(u.Limits, Limit{"Session", w.Utilization, w.ResetsAt, true})
		}
		if w := r.SevenDay; w != nil {
			u.Limits = append(u.Limits, Limit{"Weekly", w.Utilization, w.ResetsAt, true})
		}
	}
	return u, nil
}

type claudeWindow struct {
	Utilization float64   `json:"utilization"`
	ResetsAt    time.Time `json:"resets_at"`
}

func claudeLabel(kind, group string) string {
	switch {
	case kind == "weekly_all":
		return "Weekly"
	case group == "session", strings.Contains(kind, "five_hour"), strings.Contains(kind, "session"):
		return "Session"
	}
	return strings.ReplaceAll(kind, "_", " ")
}

func claudePlan(o map[string]any) string {
	sub, tier := str(o, "subscriptionType"), str(o, "rateLimitTier")
	switch {
	case strings.HasSuffix(tier, "20x"):
		return sub + " 20x"
	case strings.HasSuffix(tier, "5x"):
		return sub + " 5x"
	}
	return sub
}

// --- small HTTP/file helpers shared with codex.go ---

func getJSON(ctx context.Context, url string, hdr map[string]string, out any) error {
	req, _ := http.NewRequestWithContext(ctx, http.MethodGet, url, nil)
	for k, v := range hdr {
		req.Header.Set(k, v)
	}
	return doJSON(req, out, false)
}

func postJSON(ctx context.Context, url string, body any, hdr map[string]string, out any) error {
	b, _ := json.Marshal(body)
	req, _ := http.NewRequestWithContext(ctx, http.MethodPost, url, bytes.NewReader(b))
	req.Header.Set("Content-Type", "application/json")
	for k, v := range hdr {
		req.Header.Set(k, v)
	}
	return doJSON(req, out, true)
}

// doJSON decodes a 200 response. For token endpoints (isToken), a 400/401
// means the refresh token is dead, which is reported as errLoggedOut.
func doJSON(req *http.Request, out any, isToken bool) error {
	if err := waitTurn(req.Context(), req.URL.Host); err != nil {
		return err
	}
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		return err
	}
	defer resp.Body.Close()
	switch {
	case resp.StatusCode == http.StatusOK:
		return json.NewDecoder(resp.Body).Decode(out)
	case isToken && (resp.StatusCode == http.StatusBadRequest || resp.StatusCode == http.StatusUnauthorized):
		return errLoggedOut
	case resp.StatusCode == http.StatusUnauthorized:
		return errUnauthorized
	case resp.StatusCode == http.StatusTooManyRequests:
		return &rateLimitError{Until: time.Now().Add(retryAfter(resp.Header.Get("Retry-After")))}
	}
	return fmt.Errorf("%s: %s", req.URL.Host, resp.Status)
}

// rateLimitError reports an HTTP 429 and when it's OK to try again.
type rateLimitError struct{ Until time.Time }

func (e *rateLimitError) Error() string { return "rate limited" }

// retryAfter parses a Retry-After header (seconds or an HTTP date),
// defaulting to a minute.
func retryAfter(v string) time.Duration {
	if s, err := strconv.Atoi(strings.TrimSpace(v)); err == nil && s > 0 {
		return time.Duration(s) * time.Second
	}
	if t, err := http.ParseTime(v); err == nil && time.Until(t) > 0 {
		return time.Until(t)
	}
	return time.Minute
}

// requestSpacing is the minimum gap between requests to the same host, so
// refreshing every account at once doesn't arrive as a burst.
const requestSpacing = 750 * time.Millisecond

var throttle = struct {
	sync.Mutex
	next map[string]time.Time
}{next: map[string]time.Time{}}

// waitTurn reserves the next request slot for host and sleeps until it.
func waitTurn(ctx context.Context, host string) error {
	throttle.Lock()
	t := throttle.next[host]
	if now := time.Now(); t.Before(now) {
		t = now
	}
	throttle.next[host] = t.Add(requestSpacing)
	throttle.Unlock()
	select {
	case <-time.After(time.Until(t)):
		return nil
	case <-ctx.Done():
		return ctx.Err()
	}
}

func writeFileAtomic(path string, b []byte) error {
	tmp, err := os.CreateTemp(filepath.Dir(path), ".tmp-*")
	if err != nil {
		return err
	}
	defer os.Remove(tmp.Name())
	if err := tmp.Chmod(0o600); err != nil {
		tmp.Close()
		return err
	}
	if _, err := tmp.Write(b); err != nil {
		tmp.Close()
		return err
	}
	if err := tmp.Close(); err != nil {
		return err
	}
	return os.Rename(tmp.Name(), path)
}
