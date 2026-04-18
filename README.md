# claude-autocontinue

[![CI](https://github.com/prezis/claude-autocontinue/actions/workflows/ci.yml/badge.svg)](https://github.com/prezis/claude-autocontinue/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)

A zero-dependency bash script that watches your tmux panes and automatically
types `continue` into Claude Code sessions when their rate limit resets.

One file. No daemon. No config. Runs in any tmux pane.

```
$ claude-autocontinue &
[07:20:10] claude-autocontinue 1.1.0 starting
[07:20:10] poll=300s cooldown=60s server-cooldown=120s scrollback=200 tail=30
[07:20:15] sudo (%5): rate-limited, resets in 54m (2am)
[07:20:15]   sleeping 3270s until reset
[08:14:47] sudo (%5): reset time (2am) passed — sending continue
[08:14:47] sudo (%5): sending continue
[09:31:02] fibo (%7): server rate-limit (transient) — sending continue
[09:31:02] fibo (%7): sending continue
```

## The problem

When you run Claude Code heavily — especially across several parallel tmux
panes — you hit one of two distinct rate-limit screens that both stall the
session until you manually type `continue`:

**1. Personal usage limit** (resets at a known time):

```
You've hit your limit · resets 2am (Europe/London)
/extra-usage to finish what you're working on.
```

**2. Transient server rate limit** (Anthropic backend overload, no reset time):

```
API Error: Server is temporarily limiting requests (not your usage limit) · Rate limited
```

You then have to remember to come back later (or right now) and type
`continue`. If you have six Claude sessions in six panes, that's six manual
resumes for either failure mode.

## The approach

- **Polls every tmux pane every 5 minutes.** Uses `tmux list-panes -a` so every
  session is covered, not just the current one.
- **Detects Claude Code by TUI signature, not window name.** The `/rename`
  command inside Claude Code changes the pane title, not the tmux window name
  — so filtering by window name silently stops working when you rename a
  session. This script looks for the `⏵⏵` prompt arrow / `esc to interrupt`
  markers instead.
- **Detects the rate-limit banner only at the bottom of the pane.** Claude
  Code redraws its status at the bottom of the TUI, so a live banner always
  appears in the last ~30 lines of capture. Prose in scrollback that happens
  to mention "hit your limit" (reading this README inside a pane, for example)
  won't trigger a false send.
- **Parses the reset time and sleeps until then.** If the banner shows
  `resets 2am`, the script sleeps until 02:00:30 rather than polling every
  5 minutes for hours.
- **Also handles transient server rate limits.** If the API returns
  `Server is temporarily limiting requests (not your usage limit)`, the
  script retries immediately (no reset time exists) but enforces a longer
  120-second per-pane cooldown so it never hammers an overloaded backend.
- **60-second per-pane cooldown** (usage-limit branch) and **120-second
  per-pane cooldown** (server-limit branch). Two independent cooldown maps
  so a server hiccup in one pane doesn't block a usage-limit retry in
  another. Defense in depth against surviving banners in scrollback or
  future regex drift.
- **Stale pane guard.** If a pane is closed during the sleep-until-reset
  wait, the `send-keys` call is skipped with a "pane gone" log line.

## Install

One file, ~300 lines of bash. Drop it on your `PATH`:

```bash
git clone https://github.com/prezis/claude-autocontinue.git
sudo install -m755 claude-autocontinue/claude-autocontinue /usr/local/bin/
```

Or just run it from the clone directory:

```bash
./claude-autocontinue --help
```

### Requirements

- `bash` 4+ (for associative arrays — tested with 5.x)
- `tmux` (any recent version)
- `grep`, `sed`, `tail` (standard)
- **GNU `date`** for `-d` parsing. macOS users: `brew install coreutils` and
  the script will auto-detect `gdate`.

## Run

Start it in a spare tmux pane and leave it:

```bash
claude-autocontinue                  # default poll=300s cooldown=60s
claude-autocontinue --verbose        # log per-pane decisions
claude-autocontinue --dry-run        # detect only, never send keys (useful first time)
claude-autocontinue --interval 60    # faster polling
claude-autocontinue --log-file ~/.claude-autocontinue.log
```

Full option list: `claude-autocontinue --help`.

### Running it as a background service (systemd --user)

```bash
cat > ~/.config/systemd/user/claude-autocontinue.service <<'EOF'
[Unit]
Description=claude-autocontinue tmux watcher
After=default.target

[Service]
Type=simple
ExecStart=/usr/local/bin/claude-autocontinue --log-file %h/.claude-autocontinue.log
Restart=on-failure
RestartSec=5

[Install]
WantedBy=default.target
EOF
systemctl --user daemon-reload
systemctl --user enable --now claude-autocontinue
journalctl --user -u claude-autocontinue -f
```

## How detection works

Three independent checks. Pane signature is always required; the two banner
detectors then route to two different actions:

1. **Pane is Claude Code** — the captured content contains one of:
   `⏵⏵`, `esc to interrupt`, or `shift+tab to cycle`.
2. **Server rate-limit error (transient)** — last 30 lines match:
   ```
   API Error:[[:space:]]+Server is temporarily limiting requests
   ```
   Action: send `continue` immediately (no reset time to wait for), then
   enforce a 120-second per-pane cooldown so we don't hammer an already-
   overloaded backend. Tunable with `--server-cooldown N`.
3. **Personal usage-limit banner** — last 30 lines match
   `[Yy]ou[']ve hit your limit` OR `[Ll]imit reached` followed by whitespace +
   `·` / `∙` / `(`. Reset time is then extracted with:
   ```
   resets?[[:space:]]+[0-9]{1,2}(:[0-9]{2})?[[:space:]]*[ap]m
   ```
   …covering `resets 2am`, `resets 10:30pm`, `resets 8m`. The script then
   sleeps until the reset and sends `continue`.

The server rate-limit branch runs first: a server error in the tail is the
more recent state and warrants an immediate retry rather than a long sleep.

## Known limitations

These are called out as `KNOWN LIMITATIONS` in the source file:

- **Blocking sleep.** When one pane has a known future reset time, the script
  sleeps until that reset before polling other panes. With simultaneous reset
  windows (the common case) this is harmless; with staggered resets across
  many panes, the latest reset delays re-polling. A non-blocking rewrite
  using background subshells + `wait` is a future enhancement.
- **Timezone.** `date -d "2am"` anchors to the system's local timezone. If
  your Claude plan resets in a different zone, convert manually with
  `TZ=Europe/London`. Not yet handled automatically.
- **Cross-midnight resets.** A banner seen at 00:01 showing `resets 11:59pm`
  will parse as 23 hours in the past (because `date -d` returns today's
  23:59). Rare.
- **Modal focus.** `tmux send-keys` types wherever the pane has focus. If
  Claude Code is showing a confirm modal when `continue` is sent, the text
  goes there. Not observed in practice with the actual rate-limit screen.
- **TUI signature drift.** If Claude Code changes the `⏵⏵` glyph or the
  "esc to interrupt" wording, detection breaks silently. Run with
  `--verbose` occasionally and look for `not claude code` on panes you
  expect to be detected.

## Testing

```bash
# Static analysis
shellcheck claude-autocontinue

# Unit tests for the pure functions (needs bats-core)
bats tests/
```

The pure functions (`is_claude_code`, `has_rate_limit_banner`,
`has_server_rate_limit_error`, `parse_reset_time`, `epoch_of_reset`) are
isolated specifically so they can be sourced with `CAC_LIB_ONLY=1` and tested
without running the poll loop.

## Credits & related

- [henryaj/autoclaude](https://github.com/henryaj/autoclaude) — a polished
  Bubble Tea TUI doing the same job in Go. Recommended if you want an
  interactive per-pane enable/disable interface. This project is the
  minimalist bash alternative for people who want to read all ~300 lines of
  code in one sitting and drop it on a server as a one-file service.

## License

MIT — see [LICENSE](LICENSE).
