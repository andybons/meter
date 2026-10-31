package main

import (
	"context"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"time"
)

// Values from the installed Codex binary.
const (
	codexTokenURL = "https://auth.openai.com/oauth/token"
	codexClientID = "app_EMoamEEZ73f0CkXaXp7hrann"
	codexUsageURL = "https://chatgpt.com/backend-api/wham/usage"
)

func codexAuthPath(a *Account) string { return filepath.Join(a.dataDir(), "auth.json") }

// readCodexAuth loads auth.json as a generic map so unknown fields survive.
func readCodexAuth(a *Account) (map[string]any, map[string]any, error) {
	b, err := os.ReadFile(codexAuthPath(a))
	if err != nil {
		return nil, nil, errLoggedOut
	}
	var blob map[string]any
	if err := json.Unmarshal(b, &blob); err != nil {
		return nil, nil, fmt.Errorf("parse auth.json: %w", err)
	}
	tok, _ := blob["tokens"].(map[string]any)
	if tok == nil || str(tok, "access_token") == "" {
		return nil, nil, errLoggedOut
	}
	return blob, tok, nil
}

func fetchCodex(ctx context.Context, a *Account) (*Usage, error) {
	blob, tok, err := readCodexAuth(a)
	if err != nil {
		return nil, err
	}
	if tokenExpired(jwtExpiry(str(tok, "access_token"))) {
		if tok, err = refreshCodex(ctx, a, blob, tok); err != nil {
			return nil, err
		}
	}
	u, err := codexUsage(ctx, tok)
	if errors.Is(err, errUnauthorized) {
		if tok, err = refreshCodex(ctx, a, blob, tok); err != nil {
			return nil, err
		}
		u, err = codexUsage(ctx, tok)
	}
	return u, err
}

func refreshCodex(ctx context.Context, a *Account, blob, tok map[string]any) (map[string]any, error) {
	rt := str(tok, "refresh_token")
	if rt == "" {
		return nil, errLoggedOut
	}
	var r struct {
		IDToken      string `json:"id_token"`
		AccessToken  string `json:"access_token"`
		RefreshToken string `json:"refresh_token"`
	}
	err := postJSON(ctx, codexTokenURL, map[string]string{
		"client_id":     codexClientID,
		"grant_type":    "refresh_token",
		"refresh_token": rt,
		"scope":         "openid profile email",
	}, nil, &r)
	if err != nil {
		// Codex may have refreshed concurrently; prefer its newer tokens.
		if _, fresh, rerr := readCodexAuth(a); rerr == nil && str(fresh, "refresh_token") != rt {
			return fresh, nil
		}
		return nil, err
	}
	if r.IDToken != "" {
		tok["id_token"] = r.IDToken
	}
	tok["access_token"] = r.AccessToken
	if r.RefreshToken != "" {
		tok["refresh_token"] = r.RefreshToken
	}
	blob["tokens"] = tok
	blob["last_refresh"] = time.Now().UTC().Format(time.RFC3339Nano)
	b, err := json.MarshalIndent(blob, "", "  ")
	if err != nil {
		return nil, err
	}
	if err := writeFileAtomic(codexAuthPath(a), b); err != nil {
		return nil, fmt.Errorf("save refreshed token: %w", err)
	}
	return tok, nil
}

func codexUsage(ctx context.Context, tok map[string]any) (*Usage, error) {
	var r struct {
		PlanType  string `json:"plan_type"`
		RateLimit *struct {
			Primary   *codexWindow `json:"primary_window"`
			Secondary *codexWindow `json:"secondary_window"`
		} `json:"rate_limit"`
	}
	hdr := map[string]string{
		"Authorization": "Bearer " + str(tok, "access_token"),
		"User-Agent":    "codex_cli_rs",
	}
	if id := str(tok, "account_id"); id != "" {
		hdr["ChatGPT-Account-Id"] = id
	}
	if err := getJSON(ctx, codexUsageURL, hdr, &r); err != nil {
		return nil, err
	}
	u := &Usage{Plan: r.PlanType}
	if rl := r.RateLimit; rl != nil {
		for _, w := range []*codexWindow{rl.Primary, rl.Secondary} {
			if w != nil {
				u.Limits = append(u.Limits, Limit{
					Label:    windowLabel(w.LimitWindowSeconds),
					Percent:  w.UsedPercent,
					ResetsAt: time.Unix(w.ResetAt, 0),
					Active:   true,
				})
			}
		}
	}
	return u, nil
}

type codexWindow struct {
	UsedPercent        float64 `json:"used_percent"`
	LimitWindowSeconds int64   `json:"limit_window_seconds"`
	ResetAt            int64   `json:"reset_at"`
}

func windowLabel(secs int64) string {
	switch d := time.Duration(secs) * time.Second; {
	case d == 7*24*time.Hour:
		return "Weekly"
	case d == 5*time.Hour:
		return "Session"
	case d >= 24*time.Hour:
		return fmt.Sprintf("%dd window", int(d.Hours()/24))
	default:
		return fmt.Sprintf("%dh window", int(d.Hours()))
	}
}

type jwtClaimSet struct {
	Exp   int64  `json:"exp"`
	Email string `json:"email"`
}

// jwtClaims decodes a JWT payload without verifying the signature; it's only
// used for display and to decide whether to refresh early.
func jwtClaims(tok string) jwtClaimSet {
	var c jwtClaimSet
	parts := strings.Split(tok, ".")
	if len(parts) != 3 {
		return c
	}
	if b, err := base64.RawURLEncoding.DecodeString(parts[1]); err == nil {
		_ = json.Unmarshal(b, &c)
	}
	return c
}

func jwtExpiry(tok string) time.Time {
	if c := jwtClaims(tok); c.Exp != 0 {
		return time.Unix(c.Exp, 0)
	}
	return time.Time{}
}
