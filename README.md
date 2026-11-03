# meter

See plan usage limits across several
[Claude Code](https://claude.com/claude-code) and
[Codex](https://github.com/openai/codex) accounts, in a btop-style terminal
dashboard or a native [macOS menu bar app](#menu-bar-app). Both read the same
config and credentials.

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

- Shows every limit window (session, weekly, per-model) with time to reset.
- Refreshes on a timer and on demand. Each Claude account is asked at most
  every 2 minutes, since its usage endpoint allows only a few calls per
  token every 5 minutes; refreshes in between show the last result.
- Refreshes expired OAuth tokens and saves them back, so the `claude` and
  `codex` CLIs keep working.
- Runs `claude auth login` / `codex login` for signed-out accounts.

## Install

```sh
go install github.com/andybons/meter@latest
```

macOS is the primary target: Claude Code credentials are read from the
Keychain. On Linux, `.credentials.json` in the config dir is used instead.

## Setup

Each account needs its own config dir, set with `CLAUDE_CONFIG_DIR` (Claude
Code) or `CODEX_HOME` (Codex). The default `~/.claude` and `~/.codex` count
as one account each.

To add an account, pick a dir and log in once:

```sh
CLAUDE_CONFIG_DIR=$HOME/.claude-you@work.example claude auth login
CODEX_HOME=$HOME/.codex-you@work.example codex login
```

Then generate a config from the logins meter can find (`~/.claude`,
`~/.codex`, and any `~/.claude-*` or `~/.codex-*` dir):

```sh
meter -init
```

Or write `~/.config/meter/config.toml` by hand:

```toml
refresh = "2m"   # optional: 30s, 1m, 2m, 5m or 10m

[[claude]]
email = "you@example.com"            # no dir: the default ~/.claude

[[claude]]
email = "you@work.example"
dir   = "~/.claude-you@work.example"

[[codex]]
email = "you@example.com"            # no dir: the default ~/.codex
```

`email` is the label shown in the dashboard. `dir` must be absolute or
start with `~/`. Use the same path you pass as `CLAUDE_CONFIG_DIR`, because
Claude Code names its Keychain entry after it.

## Usage

```sh
meter                       # uses ~/.config/meter/config.toml
meter -config path.toml
meter -every 30s            # override the refresh interval
```

| Key | Action |
|---|---|
| `↑/↓`, `j/k` | select account |
| `1` / `2` | jump to the Claude / Codex panel |
| `r` | refresh all now |
| `enter` | refresh the selected account, or log in if it's signed out |
| `l` | log in to the selected account |
| `-` / `+` | change the refresh interval |
| `q` | quit |

## Menu bar app

`macos/` holds Meter, a native macOS app that lives in the menu bar as a
gauge. The gauge fills with overall usage; click it for every account's
limits.

- One section per provider, with its logo, and one row per account with a
  plan badge (Ultra, Max 5x, Pro, Team).
- Each active limit on one line: a bar, the percentage used and the time to
  reset, lined up in columns. Bars turn orange at 75% and red at 90%; a
  maxed-out limit says "Full".
- Rate-limited accounts keep their last numbers and show when they'll retry;
  signed-out accounts get a "Log In…" item that opens Terminal with the
  right login command.
- Settings: Open at Login, and how often to refresh (30 seconds to 10
  minutes). "Open Config File" opens `config.toml`, creating a starter one
  if needed.

It needs macOS 15 or later and Xcode. To install it in /Applications and
start it:

```sh
cd macos
make install
```

Then turn on **Open at Login** in Settings (⌘, from the menu) to start it
automatically. macOS may ask you to allow it in System Settings.

Development:

| Command | Does |
|---|---|
| `make` | format, then check |
| `make check` | lint, strict build and tests |
| `make app` | build `.build/Meter.app`, including its icon |
| `make run` | build and open the app from `.build` |

The app is a Swift package: `MeterCore` holds the config, credentials,
fetching and display logic with no AppKit, and has the tests; `MeterUI` is
the AppKit menu, views and Settings; `Meter` wires them together.

## How it works

- **Claude**: reads the credentials Claude Code stores in the Keychain
  (`Claude Code-credentials`, with a `-<sha256(dir)[:8]>` suffix for custom
  dirs) and calls `api.anthropic.com/api/oauth/usage`.
- **Keychain**: both versions read and write it through `/usr/bin/security`,
  which Claude Code's entries already trust, so there's no password prompt
  per account.
- **Codex**: reads `<dir>/auth.json` and calls
  `chatgpt.com/backend-api/wham/usage`. Logins started from meter set
  `cli_auth_credentials_store="file"` so the file exists.
- **Tokens**: refresh tokens rotate on use, so refreshed tokens are written
  back to where the CLI reads them. If the CLI refreshed at the same time,
  meter uses the CLI's newer token instead.
- **Rate limits**: each Claude account is asked at most every 2 minutes and
  each Codex account every 30 seconds, requests to one host are spaced
  apart, and a 429 response's `Retry-After` is honored while the last
  numbers stay on screen.
- **Login**: runs with `ANTHROPIC_API_KEY` and `OPENAI_API_KEY` removed so
  you sign in with your subscription, not API billing.

Both usage endpoints are undocumented and may change without notice.

## License

MIT. See [LICENSE](LICENSE).
