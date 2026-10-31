// Command meter is a btop-style usage dashboard for several Claude
// Code and Codex accounts. It refreshes usage on a timer (and on demand with
// r), keeps tokens fresh, and runs the provider's login flow for accounts
// that are signed out.
package main

import (
	"context"
	"errors"
	"flag"
	"fmt"
	"os"
	"time"

	tea "github.com/charmbracelet/bubbletea"
)

// Auto-refresh intervals selectable with - and +.
var intervals = []time.Duration{30 * time.Second, time.Minute, 2 * time.Minute, 5 * time.Minute, 10 * time.Minute}

type usageMsg struct {
	idx   int
	gen   int
	usage *Usage
	err   error
	at    time.Time
}

type refreshTickMsg struct{ gen int }
type clockTickMsg time.Time
type loginDoneMsg struct {
	idx int
	err error
}

type row struct {
	fetching bool
	gen      int // drops responses older than the latest request
	usage    *Usage
	err      error
	at       time.Time
}

type model struct {
	rows    []row
	cursor  int
	width   int
	height  int
	ivIdx   int
	tickGen int // invalidates the pending refresh tick when the interval changes
	now     time.Time
	status  string
}

func (m *model) interval() time.Duration { return intervals[m.ivIdx] }

func (m *model) fetch(i int) tea.Cmd {
	m.rows[i].gen++
	m.rows[i].fetching = true
	gen, a := m.rows[i].gen, accounts[i]
	return func() tea.Msg {
		ctx, cancel := context.WithTimeout(context.Background(), 20*time.Second)
		defer cancel()
		u, err := a.Fetch(ctx)
		return usageMsg{idx: i, gen: gen, usage: u, err: err, at: time.Now()}
	}
}

func (m *model) fetchAll() tea.Cmd {
	cmds := make([]tea.Cmd, len(accounts))
	for i := range accounts {
		cmds[i] = m.fetch(i)
	}
	return tea.Batch(cmds...)
}

func (m *model) scheduleRefresh() tea.Cmd {
	m.tickGen++
	gen := m.tickGen
	return tea.Tick(m.interval(), func(time.Time) tea.Msg { return refreshTickMsg{gen} })
}

func clockTick() tea.Cmd {
	return tea.Every(time.Second, func(t time.Time) tea.Msg { return clockTickMsg(t) })
}

func (m *model) login(i int) tea.Cmd {
	a := accounts[i]
	m.status = fmt.Sprintf("logging in %s %s…", a.Provider, a.Email)
	return tea.ExecProcess(a.LoginCmd(), func(err error) tea.Msg {
		return loginDoneMsg{idx: i, err: err}
	})
}

func (m *model) Init() tea.Cmd {
	return tea.Batch(m.fetchAll(), m.scheduleRefresh(), clockTick())
}

func (m *model) Update(msg tea.Msg) (tea.Model, tea.Cmd) {
	switch msg := msg.(type) {
	case tea.WindowSizeMsg:
		m.width, m.height = msg.Width, msg.Height
		// The terminal reflows existing lines on resize, so the renderer's
		// line diff no longer matches the screen. Clear and repaint fully.
		return m, tea.ClearScreen
	case clockTickMsg:
		m.now = time.Time(msg)
		return m, clockTick()
	case refreshTickMsg:
		if msg.gen != m.tickGen {
			return m, nil
		}
		return m, tea.Batch(m.fetchAll(), m.scheduleRefresh())
	case usageMsg:
		r := &m.rows[msg.idx]
		if msg.gen != r.gen {
			return m, nil
		}
		r.fetching, r.err, r.at = false, msg.err, msg.at
		if msg.err == nil {
			r.usage = msg.usage
		} else if errors.Is(msg.err, errLoggedOut) {
			r.usage = nil
		}
	case loginDoneMsg:
		m.status = ""
		if msg.err != nil {
			m.status = "login failed: " + msg.err.Error()
		}
		return m, m.fetch(msg.idx)
	case tea.KeyMsg:
		return m, m.handleKey(msg.String())
	}
	return m, nil
}

func (m *model) handleKey(k string) tea.Cmd {
	switch k {
	case "q", "esc", "ctrl+c":
		return tea.Quit
	case "up", "k":
		m.cursor = (m.cursor - 1 + len(accounts)) % len(accounts)
	case "down", "j", "tab":
		m.cursor = (m.cursor + 1) % len(accounts)
	case "1", "2":
		p := Claude
		if k == "2" {
			p = Codex
		}
		for i, a := range accounts {
			if a.Provider == p {
				m.cursor = i
				break
			}
		}
	case "r":
		// Manual refresh also restarts the auto-refresh countdown.
		return tea.Batch(m.fetchAll(), m.scheduleRefresh())
	case "enter":
		if errors.Is(m.rows[m.cursor].err, errLoggedOut) {
			return m.login(m.cursor)
		}
		return m.fetch(m.cursor)
	case "l":
		return m.login(m.cursor)
	case "+", "=":
		if m.ivIdx < len(intervals)-1 {
			m.ivIdx++
			return m.scheduleRefresh()
		}
	case "-", "_":
		if m.ivIdx > 0 {
			m.ivIdx--
			return m.scheduleRefresh()
		}
	}
	return nil
}

func main() {
	cfgPath := flag.String("config", defaultConfigPath(), "path to config file")
	initCfg := flag.Bool("init", false, "write a starter config from existing logins and exit")
	every := flag.Duration("every", 0, "auto-refresh interval, overriding the config (30s, 1m, 2m, 5m, 10m)")
	flag.Parse()

	if *initCfg {
		c, err := writeStarterConfig(*cfgPath)
		if err != nil {
			fatalf("init: %v", err)
		}
		fmt.Printf("wrote %s with %d Claude and %d Codex accounts\n", *cfgPath, len(c.Claude), len(c.Codex))
		return
	}

	accs, refresh, err := loadConfig(*cfgPath)
	switch {
	case errors.Is(err, os.ErrNotExist):
		fatalf("no config at %s\nRun `meter -init` to create one from your existing logins.", *cfgPath)
	case err != nil:
		fatalf("%s: %v", *cfgPath, err)
	case len(accs) == 0:
		fatalf("%s lists no accounts", *cfgPath)
	}
	accounts = accs
	if *every != 0 {
		refresh = *every
	}

	m := &model{rows: make([]row, len(accounts)), now: time.Now(), ivIdx: 2}
	if refresh != 0 {
		// Pick the closest preset at or above the requested interval.
		m.ivIdx = len(intervals) - 1
		for i, d := range intervals {
			if d >= refresh {
				m.ivIdx = i
				break
			}
		}
	}
	if _, err := tea.NewProgram(m, tea.WithAltScreen()).Run(); err != nil {
		fatalf("%v", err)
	}
}

func fatalf(format string, args ...any) {
	fmt.Fprintf(os.Stderr, "meter: "+format+"\n", args...)
	os.Exit(1)
}
