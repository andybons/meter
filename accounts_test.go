package main

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

// testAccounts is a fixed set used by tests that need accounts.
func testAccounts() []*Account {
	return []*Account{
		{Provider: Claude, Email: "a@example.com"},
		{Provider: Claude, Email: "b@example.com", Dir: "/home/u/.claude-b@example.com"},
		{Provider: Claude, Email: "c@example.com", Dir: "/home/u/.claude-c@example.com"},
		{Provider: Claude, Email: "d@example.com", Dir: "/home/u/.claude-d@example.com"},
		{Provider: Codex, Email: "a@example.com"},
		{Provider: Codex, Email: "b@example.com", Dir: "/home/u/.codex-b@example.com"},
		{Provider: Codex, Email: "c@example.com", Dir: "/home/u/.codex-c@example.com"},
	}
}

func TestKeychainService(t *testing.T) {
	// Claude Code suffixes the service with sha256(dir)[:8] for custom dirs.
	for _, c := range []struct{ dir, want string }{
		{"", "Claude Code-credentials"},
		{"/home/u/.claude-a@example.com", "Claude Code-credentials-aa24287f"},
	} {
		a := &Account{Provider: Claude, Dir: c.dir}
		if got := a.keychainService(); got != c.want {
			t.Errorf("dir %q: got %q, want %q", c.dir, got, c.want)
		}
	}
}

func TestEnvStripsKeysAndSetsDir(t *testing.T) {
	t.Setenv("CLAUDE_CONFIG_DIR", "/bogus")
	t.Setenv("ANTHROPIC_API_KEY", "x")
	t.Setenv("OPENAI_API_KEY", "x")
	for _, a := range testAccounts() {
		var got string
		for _, kv := range a.Env() {
			for _, bad := range []string{"ANTHROPIC_API_KEY=", "OPENAI_API_KEY=", "CLAUDE_CONFIG_DIR=/bogus"} {
				if strings.HasPrefix(kv, bad) {
					t.Errorf("%s %s: env leaks %s", a.Provider, a.Email, bad)
				}
			}
			if strings.HasPrefix(kv, a.envVar()+"=") {
				got = strings.TrimPrefix(kv, a.envVar()+"=")
			}
		}
		if got != a.Dir {
			t.Errorf("%s %s: %s=%q, want %q", a.Provider, a.Email, a.envVar(), got, a.Dir)
		}
	}
}

func TestLoadConfig(t *testing.T) {
	path := filepath.Join(t.TempDir(), "config.toml")
	os.WriteFile(path, []byte(`
refresh = "1m"

[[claude]]
email = "a@example.com"

[[claude]]
email = "b@example.com"
dir = "~/.claude-b@example.com/"

[[codex]]
email = "a@example.com"
`), 0o644)
	accs, refresh, err := loadConfig(path)
	if err != nil {
		t.Fatal(err)
	}
	if refresh != time.Minute {
		t.Errorf("refresh = %v", refresh)
	}
	if len(accs) != 3 {
		t.Fatalf("got %d accounts", len(accs))
	}
	if accs[0].Dir != "" || accs[2].Provider != Codex {
		t.Errorf("unexpected accounts: %+v", accs)
	}
	// ~ expanded and trailing slash cleaned, so the Keychain hash matches.
	if want := filepath.Join(home(), ".claude-b@example.com"); accs[1].Dir != want {
		t.Errorf("dir = %q, want %q", accs[1].Dir, want)
	}
}

func TestLoadConfigErrors(t *testing.T) {
	for name, body := range map[string]string{
		"missing email": "[[claude]]\ndir = \"~/.claude-x\"\n",
		"relative dir":  "[[claude]]\nemail = \"a@example.com\"\ndir = \"rel\"\n",
		"duplicate dir": "[[codex]]\nemail = \"a@example.com\"\n[[codex]]\nemail = \"b@example.com\"\n",
		"bad refresh":   "refresh = \"soon\"\n",
	} {
		path := filepath.Join(t.TempDir(), "config.toml")
		os.WriteFile(path, []byte(body), 0o644)
		if _, _, err := loadConfig(path); err == nil {
			t.Errorf("%s: expected error", name)
		}
	}
}

func TestWindowLabel(t *testing.T) {
	for secs, want := range map[int64]string{604800: "Weekly", 18000: "Session", 172800: "2d window"} {
		if got := windowLabel(secs); got != want {
			t.Errorf("windowLabel(%d) = %q, want %q", secs, got, want)
		}
	}
}

func TestJWTClaims(t *testing.T) {
	// header.{"exp":1700000000,"email":"a@example.com"}.sig
	tok := "e30.eyJleHAiOjE3MDAwMDAwMDAsImVtYWlsIjoiYUBleGFtcGxlLmNvbSJ9.x"
	if got := jwtExpiry(tok); !got.Equal(time.Unix(1700000000, 0)) {
		t.Errorf("jwtExpiry = %v", got)
	}
	if got := jwtClaims(tok).Email; got != "a@example.com" {
		t.Errorf("email = %q", got)
	}
}

func TestFmtInterval(t *testing.T) {
	for _, c := range []struct {
		d    time.Duration
		want string
	}{{30 * time.Second, "30s"}, {time.Minute, "1m"}, {10 * time.Minute, "10m"}} {
		if got := fmtInterval(c.d); got != c.want {
			t.Errorf("fmtInterval(%v) = %q, want %q", c.d, got, c.want)
		}
	}
}
