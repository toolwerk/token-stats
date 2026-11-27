# Token Stats for Linux (GTK, any desktop)

Generic tray widget for Linux. On KDE Plasma use the [native widget](../plasma/) instead.
Same idea as the macOS and Windows apps: Claude Code limits with a
pace mark, plus token usage per day and model with the API comparison value. Written in
Python/GTK3, a single file.

**Scope:** Claude Code only (no Codex, Antigravity or Ollama yet). Tested on KDE Plasma 6 on
Wayland only; the notes on other desktops in the README one level up are expectations, not test results. Same data sources as the other versions:

- Limits: `GET https://api.anthropic.com/api/oauth/usage` with the login from
  `~/.claude/.credentials.json` (read only, the token is never refreshed or written); further
  accounts below.
- Usage: `~/.claude/projects/**/*.jsonl`, last message per id, cache writes split by 5 m / 1 h.
- Prices: [`Sources/TokenStats/Resources/pricing.json`](../../Sources/TokenStats/Resources/pricing.json),
  so `Scripts/update-pricing.sh` updates all versions.

## Several Claude accounts

Every `CLAUDE_CONFIG_DIR` is an account of its own (SPEC §6 "Mehrere Konten je Anbieter"):

- Found automatically: `~/.claude` (default account, if the folder exists) plus every `~/.claude-*`
  or `~/.claude_*` folder that contains a `.claude.json`, and the folder in `CLAUDE_CONFIG_DIR` if
  it is set. Further folders: `TOKENSTATS_CLAUDE_DIRS=/path/one:/path/two`. Order: default,
  found automatically, then the folders from the variables. The same folder (also via a symlink)
  and the same login (`accountUuid`) count once.
- Limits per account, from `<folder>/.credentials.json`, with their own 300 s interval and
  `Retry-After`. The provider bar keeps one fixed entry "Claude" on both pages; its dot shows the
  tightest account. Below it, on "Limits" and with two or more accounts, an account bar that wraps
  onto further lines: one button per account with a state dot (colour of its tightest limit, grey
  without values) and the label in full (local part of the email, else the display name, else the
  folder name). The selected account is outlined in the accent colour; an account with a problem
  (folder missing, or a request error without earlier values) is grey with "!". Opening the popup
  selects the tightest account. The page heading reads "Claude · frank" (only "Claude" with a
  single account) and may wrap; nothing is shortened. Hints name the folder, e.g. "Nicht
  angemeldet:" followed by `CLAUDE_CONFIG_DIR=~/.claude-2 claude` and "starten". A command in a
  hint or in the empty state is shown on lines of its own in monospace and is never cut off: it
  wraps at the last space that fits; failing that after the last `=`, then `/`, then one of
  `- _ . :` (the character stays at the line end, a `.` that starts a folder name such as `~/.claude`
  is no break point), and only as a last resort after any character. A path piece therefore moves to
  the next line whole when it fits there; continuation lines are indented by two characters. The backend's `text_parts()` splits a hint into sentence parts and commands
  (`»…«`), `wrap_command()` (and `wrapCommand()` in `util.js`) does the wrapping.
- A folder from `TOKENSTATS_CLAUDE_DIRS` or `CLAUDE_CONFIG_DIR` that does not exist (an unmounted
  drive, say) stays in the account bar, grey with "!", and is never queried. Its page says in red, word for
  word as in the macOS popover, "Ordner nicht gefunden: {pfad}. Ist das Laufwerk eingehängt,
  erscheint das Konto von selbst wieder." and "Kommt der Ordner aus TOKENSTATS_CLAUDE_DIRS, dort entfernen, wenn es ihn nicht mehr
  gibt." Automatically found folders only count while they exist.
- No account at all: "Kein Claude-Konto gefunden" with "Melde dich mit »claude« an. Weitere Ordner:
  TOKENSTATS_CLAUDE_DIRS=/pfad/eins:/pfad/zwei".
- Usage stays per provider: the logs name no account and `projects` is often shared by symlink,
  so the "Verbrauch" page has no account bar and adds up the `projects` folders of all accounts
  (each real path once, messages deduplicated by id; missing folders are left out of the count).
- An expired token (`expiresAt` in the past) is reported without a request.

## Install and run

Debian/Ubuntu:

```sh
sudo apt install python3-gi python3-gi-cairo gir1.2-gtk-3.0 gir1.2-gtklayershell-0.1 libgtk-layer-shell0
python3 linux/gtk/tokenstats.py
```

Run it from a checkout, because it reads the price table from `Sources/`. For autostart put a
`.desktop` file in `~/.config/autostart/` with `Exec=python3 /path/to/linux/gtk/tokenstats.py`.

## How it behaves

- Registers its own StatusNotifierItem (no menu): a left click opens the window, centred above
  the icon. The icon is a ring in the state colour (green, yellow from 80 %, red from 100 %)
  with the percentage inside.
- The window is a [layer-shell](https://github.com/wmww/gtk-layer-shell) surface, so it sits
  directly above (or below) the panel and cannot be dragged. Esc, a click outside or another
  click on the icon closes it. Without `gir1.2-gtklayershell-0.1` it falls back to a normal
  window.
- Plasma reports the icon position in physical pixels and sends every click twice. The script
  converts with the scale from `kscreen-doctor -j` and ignores calls within 400 ms.
- The window is fixed at 400 × 640 px and not resizable: the account bar, all texts and commands
  wrap at 400 px, so the window never grows wider and nothing is clipped.
- Refreshes every 5 minutes, and never more often than every 300 s: the refresh button and a restart use the cache (`~/.cache/tokenstats/limits.json`, shared with the Plasma widget) while the last request is younger. On HTTP 429 the last values stay and the note shows when the next request is allowed (`Retry-After`).

The data part of `tokenstats.py` imports without GTK, so the account logic is tested together with
the Plasma backend: `python3 -I -m unittest discover -s linux/tests -v`.

## Limits of this version

- No settings window; the refresh interval is a constant at the top of the file.
- Plasma highlights the icon of its own applets while their popup is open. A plain
  StatusNotifierItem does not get that.
- Only the first screen is considered when positioning.
