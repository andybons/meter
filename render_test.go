package main

import (
	"errors"
	"strings"
	"testing"
	"time"
)

func TestRenderSample(t *testing.T) {
	accounts = testAccounts()
	now := time.Now()
	m := &model{rows: make([]row, len(accounts)), now: now, ivIdx: 2, width: 100}
	m.rows[0] = row{usage: &Usage{Plan: "ultra", Limits: []Limit{{"Weekly", 61, now.Add(28 * time.Hour), true}, {"Weekly · Fable", 0, now.Add(28 * time.Hour), false}}}, at: now}
	m.rows[1] = row{usage: &Usage{Plan: "max 5x", Limits: []Limit{{"Session", 93, now.Add(2 * time.Hour), true}, {"Weekly", 40, now.Add(80 * time.Hour), true}}}, at: now.Add(-3 * time.Minute)}
	m.rows[2] = row{err: errLoggedOut}
	m.rows[3] = row{err: errors.New("api.anthropic.com: 500 Internal Server Error")}
	m.rows[4] = row{usage: &Usage{Plan: "pro", Limits: []Limit{{"Weekly", 52, now.Add(94 * time.Hour), true}}}, at: now, fetching: true}
	m.rows[5] = row{err: errLoggedOut}
	m.rows[6] = row{fetching: true}
	t.Log("\n" + m.View())
	m.width = 170
	t.Log("\n" + m.View())
}

// The frame must never be taller than the window, or the alt screen scrolls.
func TestViewFitsHeight(t *testing.T) {
	accounts = testAccounts()
	now := time.Now()
	m := &model{rows: make([]row, len(accounts)), now: now, ivIdx: 2}
	for i := range m.rows {
		m.rows[i] = row{usage: &Usage{Plan: "max", Limits: []Limit{
			{"Session", 10, now.Add(time.Hour), true}, {"Weekly", 20, now.Add(48 * time.Hour), true}}}, at: now}
	}
	for _, w := range []int{100, 170} {
		for h := 3; h <= 50; h++ {
			for _, cur := range []int{0, 3, 6} {
				m.width, m.height, m.cursor = w, h, cur
				v := m.View()
				lines := strings.Split(v, "\n")
				if len(lines) > h {
					t.Fatalf("w=%d h=%d cursor=%d: %d lines", w, h, cur, len(lines))
				}
				if h >= 12 && !strings.Contains(v, accounts[cur].Email) {
					t.Errorf("w=%d h=%d: selected account %d not visible", w, h, cur)
				}
				if h >= 8 && !strings.Contains(lines[0], "claude") {
					t.Errorf("w=%d h=%d: top border missing", w, h)
				}
			}
		}
	}
}
