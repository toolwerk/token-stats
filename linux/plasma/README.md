# Token Stats for KDE Plasma 6

Native Plasma widget (QML + a small Python backend). Same idea as the macOS and Windows apps:
Claude Code limits with a pace mark, plus token usage per day and model with the API comparison
value. Being a real applet, Plasma positions the popup above the tray icon and highlights the
icon while it is open, like the clipboard or Bluetooth popups. Colours follow the Plasma theme.

**Scope:** Claude Code only (no Codex, Antigravity or Ollama yet). Needs Plasma 6, `python3`
and `rsync`. Same data sources as the other versions:

- Limits: `GET https://api.anthropic.com/api/oauth/usage` with the login from
  `~/.claude/.credentials.json` (read only, the token is never refreshed or written); further
  accounts below. The last good values are cached per account in `~/.cache/tokenstats/limits.json`, so HTTP 429 or being offline keeps
  them. The endpoint is rate limited: at most one request per 300 s, also for the refresh button
  and after a restart (the cache holds the time of the last request). After HTTP 429 the widget
  pauses until `Retry-After` has passed and shows the time.
- Usage: `~/.claude/projects/**/*.jsonl`, last message per id, cache writes split by 5 m / 1 h.
- Prices: [`Sources/TokenStats/Resources/pricing.json`](../../Sources/TokenStats/Resources/pricing.json),
  copied next to the backend on install, so `Scripts/update-pricing.sh` plus a re-install updates it.

## Several Claude accounts

Every `CLAUDE_CONFIG_DIR` is an account of its own (SPEC §6 "Mehrere Konten je Anbieter"):

- Found automatically: `~/.claude` (default account) plus every `~/.claude-*` or `~/.claude_*`
  folder that contains a `.claude.json`, and the folder in `CLAUDE_CONFIG_DIR` if it is set.
  Further folders: `TOKENSTATS_CLAUDE_DIRS=/path/one:/path/two`. The same folder (also via a
  symlink) and the same login (`accountUuid`) count once.
- Limits per account, from `<folder>/.credentials.json`, with their own 300 s interval and
  `Retry-After`. One tab per account ("Claude · frank", label = local part of the email, else
  the display name, else the folder name); with a single account nothing changes. Hints name the
  folder, e.g. `CLAUDE_CONFIG_DIR=~/.claude-2 claude` starten.
- Usage stays per provider: the logs name no account and `projects` is often shared by symlink,
  so the "Verbrauch" page adds up the `projects` folders of all accounts (each real path once,
  messages deduplicated by id).
- An expired token (`expiresAt` in the past) is reported without a request.

## Install

```sh
linux/plasma/install.sh
```

Then open the system tray settings, **Entries**, and set "Token Stats" to **Always shown**. The
script already adds it to the tray's item list; re-run it to update. It starts with the session.

Test without the panel: `plasmawindowed org.tokenstats.claude`.

## Layout

- `contents/code/backend.py` prints one JSON document (`accounts` with limits and plan each,
  31 days of usage); the
  widget runs it every 5 minutes through the `executable` data engine.
- `contents/code/util.js` formatting and aggregation; `contents/ui/*.qml` the views.

## Limits of this version

- No settings page; the refresh interval is a constant in `main.qml`.
- The UI is in German, like the macOS and Windows apps; the documentation here is still English.
- Do not update with `kpackagetool6 -u` on the installed copy, it deletes the package.
