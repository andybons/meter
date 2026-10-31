package main

import (
	"bytes"
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"time"

	"github.com/BurntSushi/toml"
)

// Config is the on-disk layout of ~/.config/meter/config.toml:
//
//	refresh = "2m"
//
//	[[claude]]
//	email = "you@example.com"          # no dir: the default ~/.claude
//
//	[[claude]]
//	email = "you@work.example"
//	dir   = "~/.claude-you@work.example"
//
//	[[codex]]
//	email = "you@example.com"          # no dir: the default ~/.codex
type Config struct {
	Refresh string          `toml:"refresh,omitempty"`
	Claude  []AccountConfig `toml:"claude"`
	Codex   []AccountConfig `toml:"codex"`
}

type AccountConfig struct {
	Email string `toml:"email"`
	// Dir is the CLAUDE_CONFIG_DIR / CODEX_HOME for this account. Leave it
	// empty for the provider's default dir. A leading ~ is expanded.
	Dir string `toml:"dir,omitempty"`
}

func defaultConfigPath() string {
	if x := os.Getenv("XDG_CONFIG_HOME"); x != "" {
		return filepath.Join(x, "meter", "config.toml")
	}
	return filepath.Join(home(), ".config", "meter", "config.toml")
}

func expandHome(p string) string {
	if p == "~" {
		return home()
	}
	if strings.HasPrefix(p, "~/") {
		return filepath.Join(home(), p[2:])
	}
	return p
}

// loadConfig reads the config file and turns it into accounts plus the
// refresh interval (zero if unset).
func loadConfig(path string) ([]*Account, time.Duration, error) {
	var c Config
	if _, err := toml.DecodeFile(path, &c); err != nil {
		return nil, 0, err
	}
	var refresh time.Duration
	if c.Refresh != "" {
		d, err := time.ParseDuration(c.Refresh)
		if err != nil {
			return nil, 0, fmt.Errorf("refresh: %w", err)
		}
		refresh = d
	}
	var out []*Account
	for _, g := range []struct {
		p    Provider
		accs []AccountConfig
	}{{Claude, c.Claude}, {Codex, c.Codex}} {
		seen := map[string]bool{}
		for i, ac := range g.accs {
			if ac.Email == "" {
				return nil, 0, fmt.Errorf("%s account #%d: email is required", strings.ToLower(g.p.String()), i+1)
			}
			dir := ""
			if ac.Dir != "" {
				// Claude Code keys its Keychain entry on this exact string, so
				// it must be absolute and clean to match what the CLI uses.
				dir = filepath.Clean(expandHome(ac.Dir))
				if !filepath.IsAbs(dir) {
					return nil, 0, fmt.Errorf("%s: dir %q must be absolute or start with ~/", ac.Email, ac.Dir)
				}
			}
			if seen[dir] {
				return nil, 0, fmt.Errorf("%s: two %s accounts share dir %q", ac.Email, g.p, ac.Dir)
			}
			seen[dir] = true
			out = append(out, &Account{Provider: g.p, Email: ac.Email, Dir: dir})
		}
	}
	return out, refresh, nil
}

// writeStarterConfig discovers existing logins and writes them as a config.
// It refuses to overwrite an existing file.
func writeStarterConfig(path string) (Config, error) {
	if _, err := os.Stat(path); err == nil {
		return Config{}, fmt.Errorf("%s already exists", path)
	}
	c := discover()
	var buf bytes.Buffer
	buf.WriteString("# meter accounts. Omit dir to use the default ~/.claude or ~/.codex.\n")
	buf.WriteString("# refresh = \"2m\"\n\n")
	if err := toml.NewEncoder(&buf).Encode(c); err != nil {
		return Config{}, err
	}
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		return Config{}, err
	}
	return c, os.WriteFile(path, buf.Bytes(), 0o644)
}

// discover finds existing logins: the default ~/.claude and ~/.codex, plus
// any ~/.claude-* and ~/.codex-* dir, reading each one's email from its own
// files. If two dirs hold the same email, the one whose name contains the
// email wins.
func discover() Config {
	var c Config
	for _, p := range []Provider{Claude, Codex} {
		prefix := ".claude"
		if p == Codex {
			prefix = ".codex"
		}
		byEmail := map[string]AccountConfig{}
		consider := func(dir string) {
			a := &Account{Provider: p, Dir: dir}
			email := accountEmail(a)
			if email == "" {
				return
			}
			ac := AccountConfig{Email: email}
			if dir != "" {
				ac.Dir = "~" + strings.TrimPrefix(dir, home())
			}
			if prev, ok := byEmail[email]; ok && (prev.Dir == "" || strings.Contains(prev.Dir, email)) {
				return
			}
			byEmail[email] = ac
		}
		consider("")
		matches, _ := filepath.Glob(filepath.Join(home(), prefix+"-*"))
		for _, m := range matches {
			if fi, err := os.Stat(m); err == nil && fi.IsDir() {
				consider(m)
			}
		}
		var list []AccountConfig
		for _, ac := range byEmail {
			list = append(list, ac)
		}
		sort.Slice(list, func(i, j int) bool {
			if (list[i].Dir == "") != (list[j].Dir == "") {
				return list[i].Dir == ""
			}
			return list[i].Email < list[j].Email
		})
		if p == Claude {
			c.Claude = list
		} else {
			c.Codex = list
		}
	}
	return c
}

// accountEmail reads which account a config dir is signed in to, or "".
func accountEmail(a *Account) string {
	if a.Provider == Codex {
		if _, tok, err := readCodexAuth(a); err == nil {
			return jwtClaims(str(tok, "id_token")).Email
		}
		return ""
	}
	// Claude keeps its state in ~/.claude.json for the default dir and in
	// <dir>/.claude.json for custom ones.
	f := filepath.Join(home(), ".claude.json")
	if a.Dir != "" {
		f = filepath.Join(a.Dir, ".claude.json")
	}
	var cfg struct {
		OAuthAccount struct {
			EmailAddress string `json:"emailAddress"`
		} `json:"oauthAccount"`
	}
	if b, err := os.ReadFile(f); err == nil && json.Unmarshal(b, &cfg) == nil {
		return cfg.OAuthAccount.EmailAddress
	}
	return ""
}
