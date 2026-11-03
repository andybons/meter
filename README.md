# meter

Usage limits for all your [Claude Code](https://claude.com/claude-code) and
[Codex](https://github.com/openai/codex) accounts, in the macOS menu bar.

<p align="center">
  <img src="docs/menu.png" width="340" alt="Meter's menu: Claude and Codex sections with each account's plan badge and a bar, percentage used and time to reset for each limit; one limit is orange at 84% and one is red and Full.">
</p>

- The menu bar icon is a gauge of overall usage.
- Each limit shows the percentage used and time to reset. Bars turn orange
  at 75% and red at 90%.
- Expired tokens are refreshed and saved back, so the `claude` and `codex`
  CLIs keep working.
- Signed-out accounts get a "Log In…" item that opens Terminal with the
  login command.

There's also a [terminal version](#terminal-version).

## Install

Requires macOS 15 and Xcode.

```sh
git clone https://github.com/andybons/meter.git
cd meter/macos
make install
```

This copies Meter to /Applications and starts it. To start it at login,
turn on **Open at Login** in Settings (⌘,).

## Accounts

Each account is a config dir, set with `CLAUDE_CONFIG_DIR` or `CODEX_HOME`.
The defaults, `~/.claude` and `~/.codex`, count as one account each. Log in
once per dir:

```sh
CLAUDE_CONFIG_DIR=$HOME/.claude-you@work.example claude auth login
CODEX_HOME=$HOME/.codex-you@work.example codex login
```

Then list the accounts in `~/.config/meter/config.toml` (**Open Config
File** in the menu creates it):

```toml
refresh = "2m"   # optional: 30s, 1m, 2m, 5m or 10m

[[claude]]
email = "you@example.com"            # no dir: ~/.claude

[[claude]]
email = "you@work.example"
dir   = "~/.claude-you@work.example"

[[codex]]
email = "you@example.com"            # no dir: ~/.codex
```

`email` is the label shown. `dir` must be absolute or start with `~/`, and
must match the `CLAUDE_CONFIG_DIR` you use: Claude Code names its Keychain
entry after it. `meter -init` from the terminal version writes this file
from the logins it finds.

## Terminal version

A btop-style terminal UI with the same data. It also runs on Linux.

```
╭─┐¹claude┌──────────────────────────────────────────────┐10:21:42┌╮
│▶ ● you@example.com                                ultra  now │
│    Weekly         ■■■■■■■■■■■■■■■■■■■■■■■■■   61% ↻ 1d 4h    │
│                                                              │
│  ● you@work.example                             team 5x  now │
│    Session        ■■■■■■■■■■■■■■■■■■■■■■■■■  100% ↻ 1h 24m   │
│    Weekly         ■■■■■■■■■■■■■■■■■■■■■■■■■   28% ↻ 5d 12h   │
╰─┐↑ select ↓┌┐login┌┐refresh┌─────────────────────────────────╯
```

```sh
go install github.com/andybons/meter@latest
meter                   # ~/.config/meter/config.toml
meter -config path.toml
meter -every 30s        # refresh interval
```

| Key | Action |
|---|---|
| `↑/↓`, `j/k` | select account |
| `1` / `2` | jump to Claude / Codex |
| `r` | refresh all |
| `enter` | refresh selected, or log in if signed out |
| `l` | log in to selected |
| `-` / `+` | change refresh interval |
| `q` | quit |

## How it works

- **Claude**: reads Claude Code's Keychain entry (`Claude Code-credentials`,
  suffixed `-<sha256(dir)[:8]>` for custom dirs) through `/usr/bin/security`,
  which the entry already trusts, so there's no password prompt. Calls
  `api.anthropic.com/api/oauth/usage`. On Linux, the terminal version reads
  `.credentials.json` instead.
- **Codex**: reads `<dir>/auth.json` and calls
  `chatgpt.com/backend-api/wham/usage`.
- **Tokens**: refresh tokens rotate on use, so new ones are written back
  where the CLI reads them. If the CLI refreshed first, its token is used.
- **Rate limits**: Claude accounts are fetched at most every 2 minutes and
  Codex accounts every 30 seconds. On a 429, the last numbers stay on screen
  until `Retry-After` passes.
- **Login**: runs without `ANTHROPIC_API_KEY` and `OPENAI_API_KEY`, so you
  sign in with your subscription rather than API billing.

Both usage endpoints are undocumented and may change.

## Development

The Mac app is a Swift package in `macos/`. `MeterCore` has the logic and
tests and doesn't import AppKit; `MeterUI` is the AppKit UI; `Meter` wires
them together.

| `make` target | Does |
|---|---|
| (none) | format, then check |
| `check` | lint, strict build, tests |
| `app` | build `.build/Meter.app` |
| `run` | build and open it |
| `install` | build, copy to /Applications, start |

`open .build/Meter.app --args --demo` shows sample accounts and reads no
config, credentials or network. It made the screenshot above.

The terminal version is the Go module at the root: `go test ./...`.

## License

MIT
