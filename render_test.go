package main

import (
	"errors"
	"testing"
	"time"
)

func TestRenderSample(t *testing.T) {
	accounts = testAccounts()
	now := time.Now()
	m := &model{rows: make([]row, len(accounts)), now: now, ivIdx: 2, width: 100}
	m.rows[0] = row{usage: &Usage{Plan: "max 20x", Limits: []Limit{{"Weekly", 61, now.Add(28 * time.Hour), true}, {"Weekly · Fable", 0, now.Add(28 * time.Hour), false}}}, at: now}
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
