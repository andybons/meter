package main

import (
	"errors"
	"fmt"
	"strings"
	"time"

	"github.com/charmbracelet/lipgloss"
	"github.com/charmbracelet/x/ansi"
	"github.com/lucasb-eyer/go-colorful"
)

// btop-ish palette.
var (
	fg       = lipgloss.Color("#cccccc")
	titleFg  = lipgloss.Color("#eeeeee")
	hiFg     = lipgloss.Color("#b54040") // hotkey letters
	dimFg    = lipgloss.Color("#5c5c5c")
	meterBg  = lipgloss.Color("#303030")
	claudeBx = lipgloss.Color("#a0603e")
	codexBx  = lipgloss.Color("#3d7b8c")

	gradLow, _  = colorful.Hex("#50b450")
	gradMid, _  = colorful.Hex("#d8c64a")
	gradHigh, _ = colorful.Hex("#d04040")

	sFg    = lipgloss.NewStyle().Foreground(fg)
	sTitle = lipgloss.NewStyle().Foreground(titleFg).Bold(true)
	sHi    = lipgloss.NewStyle().Foreground(hiFg).Bold(true)
	sDim   = lipgloss.NewStyle().Foreground(dimFg)
	sWarn  = lipgloss.NewStyle().Foreground(lipgloss.Color(gradMid.Hex()))
	sErr   = lipgloss.NewStyle().Foreground(lipgloss.Color(gradHigh.Hex()))
	sOK    = lipgloss.NewStyle().Foreground(lipgloss.Color(gradLow.Hex()))
)

// gradAt maps 0..1 to green → yellow → red, the way btop colors meters by
// position rather than by the overall value.
func gradAt(t float64) colorful.Color {
	if t < 0.5 {
		return gradLow.BlendLuv(gradMid, t*2)
	}
	return gradMid.BlendLuv(gradHigh, (t-0.5)*2)
}

func meter(p float64, width int) string {
	if width <= 0 {
		return ""
	}
	p = max(0, min(100, p))
	filled := int(p/100*float64(width) + 0.5)
	var b strings.Builder
	for i := range width {
		if i < filled {
			c := gradAt(float64(i) / float64(max(1, width-1)))
			b.WriteString(lipgloss.NewStyle().Foreground(lipgloss.Color(c.Hex())).Render("■"))
		} else {
			b.WriteString(lipgloss.NewStyle().Foreground(meterBg).Render("■"))
		}
	}
	return b.String()
}

func pctColor(p float64) lipgloss.Style {
	return lipgloss.NewStyle().Foreground(lipgloss.Color(gradAt(max(0, min(100, p)) / 100).Hex()))
}

// hotkey renders a label with one letter highlighted, e.g. hotkey("refresh", 'r').
func hotkey(label string, key rune) string {
	i := strings.IndexRune(label, key)
	if i < 0 {
		return sHi.Render(string(key)) + sFg.Render(" "+label)
	}
	return sFg.Render(label[:i]) + sHi.Render(string(key)) + sFg.Render(label[i+1:])
}

// panel draws a btop-style box: segments are embedded in the top and bottom
// borders as ┐label┌ tabs; body lines are clipped/padded to the inner width.
func panel(width int, border lipgloss.Color, topL, topR, botL []string, body []string) string {
	bs := lipgloss.NewStyle().Foreground(border)
	inner := width - 2
	tabs := func(segs []string) string {
		var s string
		for _, seg := range segs {
			s += bs.Render("┐") + seg + bs.Render("┌")
		}
		return s
	}
	edge := func(l, r, left, right string) string {
		fill := width - 2 - lipgloss.Width(left) - lipgloss.Width(right) - 1
		if fill < 0 {
			left, fill = "", width-3-lipgloss.Width(right)
		}
		if fill < 0 {
			right, fill = "", width-3
		}
		return bs.Render(l+"─") + left + bs.Render(strings.Repeat("─", fill)) + right + bs.Render(r)
	}
	out := []string{edge("╭", "╮", tabs(topL), tabs(topR))}
	for _, line := range body {
		line = ansi.Truncate(line, inner, "…")
		pad := inner - lipgloss.Width(line)
		out = append(out, bs.Render("│")+line+strings.Repeat(" ", max(0, pad))+bs.Render("│"))
	}
	out = append(out, edge("╰", "╯", tabs(botL), ""))
	return strings.Join(out, "\n")
}

func compactDur(d time.Duration) string {
	if d > 0 && d < time.Minute {
		return fmt.Sprintf("%ds", int(d.Seconds()))
	}
	d = d.Round(time.Minute)
	switch {
	case d <= 0:
		return "now"
	case d >= 24*time.Hour:
		return fmt.Sprintf("%dd %dh", int(d.Hours())/24, int(d.Hours())%24)
	case d >= time.Hour:
		return fmt.Sprintf("%dh %dm", int(d.Hours()), int(d.Minutes())%60)
	}
	return fmt.Sprintf("%dm", int(d.Minutes()))
}

func (m *model) agoStr(t time.Time) string {
	if t.IsZero() {
		return ""
	}
	if d := m.now.Sub(t); d >= time.Minute {
		return fmt.Sprintf("%dm ago", int(d.Minutes()))
	}
	return "now"
}

// accountLines renders one account: a header line plus one meter per limit.
func (m *model) accountLines(i, inner int) []string {
	a, r := accounts[i], m.rows[i]
	sel := i == m.cursor

	dot := sOK.Render("●")
	switch {
	case r.fetching && r.usage == nil && r.err == nil:
		dot = sDim.Render("○")
	case errors.Is(r.err, errLoggedOut), errors.As(r.err, new(*rateLimitError)):
		dot = sWarn.Render("●")
	case r.err != nil:
		dot = sErr.Render("●")
	}
	marker, email := "  ", sFg.Bold(true).Render(a.Email)
	if sel {
		marker = sHi.Render("▶ ")
		email = sTitle.Underline(true).Render(a.Email)
	}
	right := ""
	if r.usage != nil && r.usage.Plan != "" {
		right = sDim.Render(r.usage.Plan) + "  "
	}
	if r.fetching {
		right += sDim.Render("⟳")
	} else {
		right += sDim.Render(m.agoStr(r.at))
	}
	left := marker + dot + " " + email
	gap := max(1, inner-1-lipgloss.Width(left)-lipgloss.Width(right))
	lines := []string{left + strings.Repeat(" ", gap) + right}

	const labelW, pctW, resetW = 15, 5, 9
	barW := max(6, inner-4-labelW-pctW-resetW-3)
	var rl *rateLimitError
	switch {
	case errors.Is(r.err, errLoggedOut):
		lines = append(lines, "    "+sWarn.Render("logged out")+sDim.Render(" · press ")+sHi.Render("⏎")+sDim.Render(" to log in"))
		return lines
	case errors.As(r.err, &rl):
		lines = append(lines, "    "+sWarn.Render("rate limited")+sDim.Render(" · retrying in "+compactDur(rl.Until.Sub(m.now))))
	case r.err != nil:
		lines = append(lines, "    "+sErr.Render(r.err.Error()))
	}
	// Last known usage stays visible through errors and rate limits.
	switch {
	case r.usage == nil && r.err == nil:
		lines = append(lines, "    "+sDim.Render("loading…"))
	case r.usage != nil && len(r.usage.Limits) == 0:
		lines = append(lines, "    "+sDim.Render("no limits reported"))
	case r.usage != nil:
		for _, l := range r.usage.Limits {
			ls := sFg
			if !l.Active {
				ls = sDim
			}
			label := ls.Render(ansi.Truncate(fmt.Sprintf("%-*s", labelW, l.Label), labelW, "…"))
			pct := pctColor(l.Percent).Render(fmt.Sprintf("%*.0f%%", pctW-1, l.Percent))
			reset := ""
			if !l.ResetsAt.IsZero() {
				reset = sDim.Render(fmt.Sprintf("↻ %-*s", resetW-2, compactDur(l.ResetsAt.Sub(m.now))))
			}
			lines = append(lines, "    "+label+meter(l.Percent, barW)+" "+pct+" "+reset)
		}
	}
	return lines
}

// panelBody returns p's account lines, with a blank line between accounts
// when spaced, and the line range [selFrom, selTo) of the selected account
// (selFrom = -1 if it isn't in this panel).
func (m *model) panelBody(p Provider, inner int, spaced bool) (body []string, selFrom, selTo int) {
	selFrom = -1
	for i, a := range accounts {
		if a.Provider != p {
			continue
		}
		if len(body) > 0 && spaced {
			body = append(body, "")
		}
		if i == m.cursor {
			selFrom = len(body)
		}
		body = append(body, m.accountLines(i, inner)...)
		if i == m.cursor {
			selTo = len(body)
		}
	}
	return body, selFrom, selTo
}

// clipBody keeps at most n lines of body, scrolled so the selected account
// stays in view. It reports whether lines were hidden above and below.
func clipBody(body []string, n, selFrom, selTo int) (out []string, above, below bool) {
	if len(body) <= n {
		return body, false, false
	}
	n = max(n, 0)
	off := 0
	if selFrom >= 0 {
		if selTo > n {
			off = selTo - n
		}
		off = min(off, selFrom)
	}
	return body[off : off+n], off > 0, off+n < len(body)
}

func (m *model) providerPanel(p Provider, width int, body []string, above, below bool) string {
	num, name, color := "¹", "claude", claudeBx
	if p == Codex {
		num, name, color = "²", "codex", codexBx
	}
	topL := []string{sDim.Render(num) + sTitle.Render(name)}
	var topR, botL []string
	if p == Claude {
		topR = []string{sTitle.Render(m.now.Format("15:04:05"))}
		botL = []string{sHi.Render("↑") + sFg.Render(" select ") + sHi.Render("↓"), hotkey("login", 'l'), hotkey("refresh", 'r')}
	} else {
		topR = []string{sHi.Render("-") + sFg.Render(" "+fmtInterval(m.interval())+" ") + sHi.Render("+")}
		botL = []string{hotkey("quit", 'q')}
		if m.status != "" {
			botL = append(botL, sWarn.Render(m.status))
		}
	}
	switch {
	case above && below:
		botL = append(botL, sDim.Render("↕ more"))
	case above:
		botL = append(botL, sDim.Render("↑ more"))
	case below:
		botL = append(botL, sDim.Render("↓ more"))
	}
	return panel(width, color, topL, topR, botL, body)
}

// View always fits the window: an alt-screen frame taller than the terminal
// scrolls, which leaves stale lines in the scrollback. When the accounts
// don't fit, the blank lines between them go first, then each panel shows a
// window around the selected account.
func (m *model) View() string {
	w, h := m.width, m.height
	if w == 0 {
		w = 100
	}
	if h == 0 {
		h = 1 << 20
	}
	// Side by side when there's room for two readable panels, else stacked.
	side := w >= 150
	lw := w
	if side {
		lw = w / 2
	}
	widths := map[Provider]int{Claude: lw, Codex: w - lw}
	if !side {
		widths[Codex] = w
	}
	type pb struct {
		body           []string
		selFrom, selTo int
	}
	var b map[Provider]pb
	fits := func() bool {
		c, x := len(b[Claude].body), len(b[Codex].body)
		if side {
			return max(c, x)+2 <= h
		}
		return c+x+4 <= h
	}
	for _, spaced := range []bool{true, false} {
		b = map[Provider]pb{}
		for _, p := range []Provider{Claude, Codex} {
			body, f, t := m.panelBody(p, widths[p]-2, spaced)
			b[p] = pb{body, f, t}
		}
		if fits() {
			break
		}
	}

	// Line budget per panel body.
	budget := map[Provider]int{}
	if side {
		budget[Claude], budget[Codex] = h-2, h-2
	} else {
		avail := h - 4
		sel, other := Claude, Codex
		if b[Codex].selFrom >= 0 {
			sel, other = Codex, Claude
		}
		// The selected panel gets what it needs, but at least half.
		budget[sel] = min(len(b[sel].body), max(avail-len(b[other].body), (avail+1)/2))
		budget[other] = avail - budget[sel]
	}
	panels := map[Provider]string{}
	for _, p := range []Provider{Claude, Codex} {
		body, above, below := clipBody(b[p].body, budget[p], b[p].selFrom, b[p].selTo)
		if side {
			// Pad so side-by-side panels are the same height.
			for n := min(max(len(b[Claude].body), len(b[Codex].body)), h-2); len(body) < n; {
				body = append(body, "")
			}
		}
		panels[p] = m.providerPanel(p, widths[p], body, above, below)
	}
	var out string
	if side {
		out = lipgloss.JoinHorizontal(lipgloss.Top, panels[Claude], panels[Codex])
	} else {
		out = panels[Claude] + "\n" + panels[Codex]
	}
	// Last resort for windows too short for even the borders.
	if lines := strings.Split(out, "\n"); len(lines) > h {
		out = strings.Join(lines[:h], "\n")
	}
	return out
}

func fmtInterval(d time.Duration) string {
	if d%time.Minute == 0 {
		return fmt.Sprintf("%dm", int(d.Minutes()))
	}
	return fmt.Sprintf("%ds", int(d.Seconds()))
}
