#!/usr/bin/env python3
"""Linux tray port of mahype/token-stats (MIT), Claude Code only.

Limits come from api.anthropic.com/api/oauth/usage, token counts from ~/.claude/projects/**/*.jsonl,
prices from Sources/TokenStats/Resources/pricing.json of this repo (list prices = API comparison value).
Several accounts (SPEC §6 „Mehrere Konten je Anbieter“): every CLAUDE_CONFIG_DIR is an account of its own, see
discover_accounts(); limits per account, usage over the logs of all accounts. A folder from CLAUDE_CONFIG_DIR or
TOKENSTATS_CLAUDE_DIRS that does not exist stays in the account bar (grey with "!") and is never queried.
The data part imports without GTK, so linux/tests can check it on any machine.
"""
import hashlib, json, os, sys, glob, re, subprocess, threading, time, urllib.request, urllib.error
from collections import defaultdict
from datetime import datetime, timedelta, timezone

# gtk-layer-shell must be loaded before libwayland-client, so re-exec once with LD_PRELOAD
if __name__ == "__main__":
    _LAYER_LIB = next(iter(glob.glob("/usr/lib*/**/libgtk-layer-shell.so.0", recursive=True)), None)
    if _LAYER_LIB and _LAYER_LIB not in os.environ.get("LD_PRELOAD", ""):
        os.environ["LD_PRELOAD"] = (_LAYER_LIB + " " + os.environ.get("LD_PRELOAD", "")).strip()
        os.execv(sys.executable, [sys.executable] + sys.argv)

try:
    import cairo  # noqa: F401  (needed for the draw callbacks)
    import gi
    gi.require_foreign("cairo")
    gi.require_version("Gtk", "3.0")
    from gi.repository import Gtk, Gdk, GLib, Gio, Pango
except ImportError:
    if __name__ == "__main__":
        raise
    # Nur für linux/tests: ohne GTK importierbar, damit sich die Kontologik prüfen lässt. Die Oberfläche läuft so nicht.
    cairo = gi = Gdk = GLib = Gio = Pango = None
    Gtk = type("Gtk", (), {"DrawingArea": object, "Window": object, "Label": object})

LayerShell = None
if gi:
    try:
        gi.require_version("GtkLayerShell", "0.1")
        from gi.repository import GtkLayerShell as LayerShell
    except (ValueError, ImportError):
        LayerShell = None

HOME = os.path.expanduser("~")
HERE = os.path.dirname(os.path.abspath(__file__))
CLAUDE_DIRS_ENV = "TOKENSTATS_CLAUDE_DIRS"
ICON_DIR = f"{HOME}/.cache/tokenstats"
INTERVAL_S = 300
WIDTH, HEIGHT = 400, 640   # Fenster fest 400 px breit, siehe Popup
# Der Usage-Endpunkt ist hart rate-limitiert: höchstens eine Abfrage alle 300 s, auch bei Klick auf
# „Aktualisieren“ oder nach einem Neustart. Der Stand liegt im Cache,
# den sich diese Fassung mit dem Plasma-Widget teilt.
MIN_INTERVAL_S = 300
LIMITS_CACHE = f"{ICON_DIR}/limits.json"
_LIMITS_LOCK = threading.Lock()

GREEN, YELLOW, RED = (0.30, 0.75, 0.50), (0.89, 0.66, 0.24), (0.85, 0.30, 0.30)
# Rot für Sätze (nicht für Balken und Prozente): auf dem festen Grund #1e1e1e hat RED (#d94c4c) nur 4,0:1,
# #f59a8a 7,8:1 – dieselbe Textfarbe wie auf macOS und Windows im Dunkeln
RED_TEXT = "#f59a8a"
BLUE, BLUE_DIM, GREY = (0.0, 0.57, 1.0), (0.06, 0.37, 0.64), (0.55, 0.55, 0.55)
WINDOWS = {"session": 5 * 3600, "weekly_all": 7 * 86400, "weekly_scoped": 7 * 86400}

# Zustand eines Kontoeintrags und Texte (Textkatalog „Mehrere Konten“, Abschnitte „Modell“ und „Linux“)
OK, MISSING_FOLDER = "ok", "missingFolder"
# Wie in den Einstellungen auf macOS und Windows; der Pfad steht darüber auf eigener Zeile (Feld „folder“)
MISSING_FOLDER_TEXT = ("Ordner nicht gefunden. Das Konto steht grau im Menü. "
                       "Ist das Laufwerk eingehängt, wird es wieder abgefragt.")
MISSING_FOLDER_HINT = "Kommt der Ordner aus TOKENSTATS_CLAUDE_DIRS, dort entfernen, wenn es ihn nicht mehr gibt."
EMPTY_TITLE = "Kein Claude-Konto gefunden"

# Befehle in Hinweisen stehen in »…« (ältere Cache-Einträge: `…`). Die Anzeige setzt jeden Befehl in Monospace
# auf eigene Zeilen, umgebrochen mit wrap_command (QML: wrapCommand in util.js, dieselbe Regel).
COMMAND_RE = re.compile(r"»([^«]*)«|`([^`]*)`")
# leerer Zustand, direkt als Teile (Textkatalog „Mehrere Konten“, Abschnitt „Linux“)
EMPTY_PARTS = [{"kind": "text", "text": "Melde dich mit"}, {"kind": "cmd", "text": "claude"},
               {"kind": "text", "text": "an. Weitere Ordner:"},
               {"kind": "cmd", "text": "TOKENSTATS_CLAUDE_DIRS=/pfad/eins:/pfad/zwei"}]


def text_parts(text):
    """Satz -> [{kind: "text"|"cmd", text}]; Befehle ohne »…«, leere Teile fallen weg."""
    parts, pos = [], 0
    text = text or ""

    def add(kind, chunk):
        chunk = chunk.strip()
        if chunk:
            parts.append({"kind": kind, "text": chunk})

    for m in COMMAND_RE.finditer(text):
        add("text", text[pos:m.start()])
        add("cmd", m.group(1) if m.group(1) is not None else m.group(2))
        pos = m.end()
    add("text", text[pos:])
    return parts


# Zeichen, nach denen ein Befehl umbrechen darf, wenn kein Leerzeichen passt, in dieser Rangfolge (das Zeichen
# bleibt am Zeilenende). So wandert ein Pfadstück ganz in die nächste Zeile, wenn es dort passt.
COMMAND_BREAK_RANKS = ("=", "/", "-_.:")


def _command_break(text, limit):
    """Länge der Zeile bei einem Bruch nach einem Zeichen aus COMMAND_BREAK_RANKS (der höchste Rang gewinnt,
    darin der letzte passende), sonst limit (harter Bruch). Ein „.“, mit dem ein Ordnername beginnt (am
    Tokenanfang oder direkt nach „/“, „=“, „~“), ist kein Bruchpunkt."""
    for chars in COMMAND_BREAK_RANKS:
        for i in range(min(limit, len(text)) - 1, -1, -1):
            c = text[i]
            if c in chars and not (c == "." and (i == 0 or text[i - 1] in "/=~ ")):
                return i + 1
    return limit


# Kurze Befehle ohne Leerzeichen (»claude«) stehen im Satz statt allein auf einer Zeile („Melde dich mit claude an.“)
INLINE_COMMAND_MAX = 16


def inline_parts(parts, max_chars=INLINE_COMMAND_MAX):
    """Teile -> Teile für die Anzeige: Text-Teile und kurze Befehle (ohne Leerzeichen, höchstens max_chars Zeichen)
    werden zu einem Text-Teil mit „segments“ [{text, mono}] zusammengefasst (mit Leerzeichen verbunden; „text“
    ist der ganze Satz ohne Auszeichnung). Längere Befehle bleiben eigene Teile (kind „cmd“, wrap_command)."""
    out = []
    for part in parts:
        short = (part["kind"] == "cmd" and len(part["text"]) <= max_chars
                 and not any(c.isspace() for c in part["text"]))
        if part["kind"] != "text" and not short:
            out.append(dict(part))
            continue
        segment = {"text": part["text"], "mono": part["kind"] == "cmd"}
        if out and out[-1]["kind"] == "text":
            out[-1]["segments"].append(segment)
            out[-1]["text"] += " " + part["text"]
        else:
            out.append({"kind": "text", "text": part["text"], "segments": [segment]})
    return out


def segments_markup(segments):
    """Segmente als Pango-Markup, Befehle in Monospace."""
    def escape(text):
        return text.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;")
    return " ".join(f'<span font_family="monospace">{escape(seg["text"])}</span>' if seg["mono"] else escape(seg["text"])
                    for seg in segments)


def command_label_widths(char_width, command, min_chars):
    """(Mindest-, natürliche) Breite eines CommandLabel in Pixeln: mindestens min_chars Zeichen, ein kürzerer
    Befehl nur so breit wie er selbst – die natürliche Breite ist nie kleiner als die Mindestbreite."""
    length = len(" ".join(str(command).split()))
    return int(char_width * min(min_chars, length)) + 1, int(char_width * length) + 1


def wrap_command(command, max_chars, indent=2):
    """Monospace-Befehl -> Zeilen mit höchstens max_chars Zeichen, Folgezeilen um indent Leerzeichen eingerückt
    (die Einrückung zählt mit). Bruch am letzten passenden Leerzeichen, sonst nach dem letzten „=“, sonst nach
    dem letzten „/“, sonst nach „- _ . :“ (siehe _command_break), sonst hart nach max_chars Zeichen; führende
    Leerzeichen einer Folgezeile entfallen. Nichts geht verloren."""
    text = " ".join(str(command).split())
    max_chars = max(1, int(max_chars))
    indent = max(0, min(indent, max_chars - 1))
    lines, first = [], True
    while text:
        limit = max_chars if first else max_chars - indent
        if len(text) <= limit:
            line, text = text, ""
        else:
            cut = text.rfind(" ", 0, limit + 1)
            if cut > 0:
                line, text = text[:cut], text[cut + 1:]
            else:
                cut = _command_break(text, limit)
                line, text = text[:cut], text[cut:]
        lines.append(line if first else " " * indent + line)
        text, first = text.lstrip(" "), False
    return lines


CSS = b"""
window.ts { background: #1e1e1e; color: #e6e6e6; }
.ts-title { font-size: 20px; font-weight: bold; }
.ts-dim { color: #9a9a9a; }
.ts-h { font-size: 16px; font-weight: bold; }
.ts-big { font-size: 24px; font-weight: bold; }
.ts-mono { font-family: monospace; }
.ts-card { background: #2c2c2c; border-radius: 12px; padding: 12px 14px; }
.ts-pill { border: 1px solid; border-radius: 99px; padding: 1px 10px; font-weight: bold; }
.ts-chip { background: #2c2c2c; border-radius: 8px; padding: 6px 10px; font-family: monospace; }
.ts-foot { background: #242424; padding: 10px 16px; }
button.ts-tab { background: none; border: none; border-radius: 0; box-shadow: none; color: #9a9a9a;
                padding: 6px 12px; font-weight: bold; border-bottom: 3px solid transparent; }
button.ts-tab:checked { color: #fff; border-bottom-color: #0a84ff; }
button.ts-seg { background: #2c2c2c; border: none; border-radius: 8px; box-shadow: none; color: #9a9a9a; padding: 3px 14px; }
button.ts-seg:checked { background: #3a3a3a; color: #fff; font-weight: bold; }
button.ts-range { background: none; border: none; box-shadow: none; color: #9a9a9a; padding: 2px 6px; }
button.ts-range:checked { color: #fff; font-weight: bold; }
button.ts-acc { background: #2c2c2c; border: 1px solid #3a3a3a; border-radius: 8px; box-shadow: none;
                color: #e6e6e6; padding: 3px 10px; }
button.ts-acc:hover { background: #343434; }
button.ts-acc.ts-sel { background: rgba(10, 132, 255, 0.18); border-color: #0a84ff; }
button.ts-acc.ts-problem, button.ts-acc.ts-problem label { color: #9a9a9a; }
.ts-bold { font-weight: bold; }
"""


# ---------- data ----------

def folder_hash(path):
    """Wie Claude Code für den Schlüsselbund bei CLAUDE_CONFIG_DIR: erste 8 Hex-Zeichen von SHA-256(Pfad)."""
    return hashlib.sha256(path.encode()).hexdigest()[:8]


def short_path(path):
    return "~" + path[len(HOME):] if path.startswith(HOME + "/") else path


def read_account(path):
    try:
        with open(path) as f:
            account = json.load(f).get("oauthAccount")
    except (OSError, ValueError, AttributeError):
        return {}
    return account if isinstance(account, dict) else {}


def discover_accounts():
    """-> [{id, folder, dir, label, source, state}] in der Reihenfolge Standard, automatisch gefunden, von Hand.

    Standard: ~/.claude, nur wenn der Ordner da ist. Automatisch: ~/.claude-*/~/.claude_* mit .claude.json.
    Von Hand: CLAUDE_CONFIG_DIR und TOKENSTATS_CLAUDE_DIRS; fehlt so ein Ordner, bleibt das Konto mit
    Zustand „missingFolder“ in der Liste und wird nicht abgefragt. Derselbe Ordner (auch per Symlink) und
    dieselbe Anmeldung (accountUuid) zählen nur einmal, es gilt der zuerst gefundene Eintrag."""
    try:
        names = sorted(n for n in os.listdir(HOME) if n.startswith((".claude-", ".claude_")))
    except OSError:
        names = []
    candidates = [(None, "default")] + [(f"{HOME}/{n}", "auto") for n in names
                                        if os.path.isdir(f"{HOME}/{n}") and os.path.isfile(f"{HOME}/{n}/.claude.json")]
    for extra in [os.environ.get("CLAUDE_CONFIG_DIR", "")] + os.environ.get(CLAUDE_DIRS_ENV, "").split(":"):
        if extra:
            candidates.append((os.path.abspath(os.path.expanduser(extra)).rstrip("/"), "manual"))
    accounts, real_seen, uuid_seen = [], set(), set()
    for folder, source in candidates:
        path = folder or f"{HOME}/.claude"
        exists = os.path.isdir(path)
        if not exists and source != "manual":
            continue   # Standardkonto ohne ~/.claude: noch nie angemeldet, also kein Konto
        real = os.path.realpath(path)
        if real in real_seen:
            continue
        real_seen.add(real)
        account = read_account(f"{folder}/.claude.json" if folder else f"{HOME}/.claude.json") if exists else {}
        uuid = account.get("accountUuid")
        if uuid in uuid_seen:
            continue   # zweimal dieselbe Anmeldung: sonst doppelte Abfragen gegen dasselbe Rate-Limit
        if uuid:
            uuid_seen.add(uuid)
        email, name = account.get("emailAddress") or "", account.get("displayName") or ""
        label = email.split("@")[0] or name or (os.path.basename(folder).lstrip(".") if folder else "Standard")
        accounts.append({"id": f"claude@{folder_hash(folder)}" if folder else "claude",
                         "folder": folder, "dir": path, "label": label, "source": source,
                         "state": OK if exists else MISSING_FOLDER})
    return accounts


def worst_pct(info):
    """Höchster Prozentwert eines Stands, None ohne Stand oder ohne Limits."""
    return max((l["pct"] for l in (info or {}).get("limits") or []), default=None)


def tightest_id(accounts):
    """[{id, info}] -> ID des knappsten Kontos (höchstes Limit, bei Gleichstand das frühere);
    hat keins einen Stand, das erste; ohne Konten None."""
    best, best_pct = None, None
    for account in accounts:
        pct = worst_pct(account.get("info"))
        if pct is not None and (best_pct is None or pct > best_pct):
            best, best_pct = account["id"], pct
    return best or (accounts[0]["id"] if accounts else None)


def account_view(account, info, note, count):
    """Eintrag für die Anzeige. problem = grau mit „!“: Ordner fehlt, oder Abruffehler ohne Stand."""
    missing = account["state"] == MISSING_FOLDER
    return {"id": account["id"], "label": account["label"], "state": account["state"],
            "title": f"Claude · {account['label']}" if count > 1 else "Claude",
            "folder": short_path(account["dir"]) if account["folder"] else None,
            "info": info, "note": note, "pct": worst_pct(info),
            "problem": missing or (not info and bool(note)),
            "missing": MISSING_FOLDER_TEXT if missing else None,
            "missingHint": MISSING_FOLDER_HINT if missing else None}


def footer_note(page, account, usage_note):
    """Hinweis in der Fußzeile: auf „Limits“ der des Kontos, aber nur mit Stand – ohne Stand steht er schon im
    Inhalt (render_limits) und nicht noch einmal unten; auf „Verbrauch“ der Hinweis zum Einlesen."""
    if page != "limits":
        return usage_note
    return account["note"] if account and account.get("info") else None


def prefixed(prefix, parts):
    """Stellt prefix vor die Teile; beginnen sie mit Text, auf derselben Zeile."""
    if parts and parts[0]["kind"] == "text":
        return [{"kind": "text", "text": f"{prefix} {parts[0]['text']}"}] + parts[1:]
    return [{"kind": "text", "text": prefix}] + parts


def pick_account(accounts, current_id):
    """Gewähltes Konto: das mit current_id, sonst das knappste, ohne Konten None."""
    by_id = {a["id"]: a for a in accounts}
    return by_id.get(current_id) or by_id.get(tightest_id(accounts))


def claude_command(account, args=""):
    """Befehl für Hinweise, in »…« (text_parts macht daraus eine eigene Zeile): beim zweiten Konto mit Ordner,
    ein schlichtes »claude« erneuert nur das Standardkonto."""
    prefix = f"CLAUDE_CONFIG_DIR={short_path(account['folder'])} " if account["folder"] else ""
    return f"»{prefix}claude{args}«"


def load_creds(account):
    return json.load(open(f"{account['dir']}/.credentials.json"))["claudeAiOauth"]


def plan_label(c):
    tier = c.get("rateLimitTier") or ""
    m = re.search(r"max_(\d+)x", tier)
    return f"{c.get('subscriptionType', '').title()}{f' {m.group(1)}×' if m else ''}"


def fetch_limits(c):
    req = urllib.request.Request(
        "https://api.anthropic.com/api/oauth/usage",
        headers={"Authorization": f"Bearer {c['accessToken']}", "anthropic-beta": "oauth-2025-04-20",
                 "User-Agent": "claude-code/2"})
    data = json.load(urllib.request.urlopen(req, timeout=15))
    rows = []
    for l in data.get("limits") or []:
        model = ((l.get("scope") or {}).get("model") or {}).get("display_name")
        if l["kind"] == "session":
            title, sub = "Session", "5 h"
        elif l["kind"] == "weekly_all":
            title, sub = "Woche", "7 d, alle Modelle"
        else:
            title, sub = model or l["kind"].replace("_", " ").title(), "Wochenlimit"
        rows.append({"title": title, "sub": sub, "pct": l["percent"], "reset": l.get("resets_at"),
                     "window": WINDOWS.get(l["kind"], 7 * 86400)})
    extra = data.get("extra_usage") or {}
    if extra.get("is_enabled"):
        div = 10 ** extra.get("decimal_places", 2)
        cur = {"EUR": "€", "USD": "$"}.get(extra.get("currency"), extra.get("currency", ""))
        extra = f"Extra {extra['used_credits'] / div:,.2f} {cur} / {extra['monthly_limit'] / div:,.2f} {cur}"
    else:
        extra = None
    return {"plan": plan_label(c), "limits": rows, "extra": extra}


def read_cache():
    """-> {"accounts": {id: {info, attemptedAt, retryAt, error}}}"""
    try:
        with open(LIMITS_CACHE) as f:
            d = json.load(f)
    except (OSError, ValueError):
        return {"accounts": {}}
    if not isinstance(d, dict):
        return {"accounts": {}}
    if isinstance(d.get("accounts"), dict):
        return d
    # ältere Fassungen ohne Konten: Stand des Standardkontos (ganz alt: nur der Stand, ohne Zeitstempel)
    old = {"info": d, "attemptedAt": 0} if "limits" in d else d
    return {"accounts": {"claude": old} if old else {}}


def write_cache(cache):
    try:
        os.makedirs(ICON_DIR, exist_ok=True)
        tmp = f"{LIMITS_CACHE}.{os.getpid()}.tmp"   # atomar ersetzen, damit kein Leser eine halbe Datei sieht
        with open(tmp, "w") as f:
            json.dump(cache, f)
        os.replace(tmp, LIMITS_CACHE)
    except OSError:
        pass


def hhmm(ts):
    return datetime.fromtimestamp(ts).strftime("%H:%M")


def limits_with_cache(account):
    with _LIMITS_LOCK:   # zwei schnelle Klicks fragen nicht doppelt ab
        return _limits_with_cache(account)


def save_entry(account, entry):
    cache = read_cache()   # frisch lesen: Plasma und GTK schreiben dieselbe Datei
    cache["accounts"][account["id"]] = entry
    write_cache(cache)


def _limits_with_cache(account):
    """-> (Stand, Fehlertext) eines Kontos. Fragt nur ab, wenn dessen letzte Abfrage lang genug her ist."""
    if account.get("state") == MISSING_FOLDER:
        return None, None   # Ordner fehlt: nicht abfragen, die Seite erklärt es
    now = time.time()
    entry = read_cache()["accounts"].get(account["id"]) or {}
    info = entry.get("info")
    retry_at = entry.get("retryAt", 0)
    if now < retry_at:
        return info, f"Abfrage pausiert (Rate-Limit) · wieder ab {hhmm(retry_at)}"
    if now - entry.get("attemptedAt", 0) < MIN_INTERVAL_S:
        return info, entry.get("error")
    try:
        creds = load_creds(account)
    except (OSError, ValueError, KeyError, TypeError):
        # keine Anfrage an den Endpunkt, also auch keine Drosselung
        return info, f"Nicht angemeldet: {claude_command(account)} starten"
    if not creds.get("accessToken"):
        return info, f"Nicht angemeldet: {claude_command(account, ' auth login')} ausführen"
    if (creds.get("expiresAt") or now * 1000) / 1000 < now:
        # Ablaufzeit lokal geprüft: keine Anfrage, also zählt der Versuch nicht gegen das Intervall
        return info, f"Anmeldung abgelaufen: {claude_command(account)} starten"
    # Versuch vor der Anfrage festhalten, damit parallele Aufrufe (Plasma, GTK) nicht zugleich abfragen
    entry.update({"attemptedAt": now, "retryAt": 0, "error": None})
    save_entry(account, entry)
    try:
        entry["info"] = fetch_limits(creds)
    except urllib.error.HTTPError as e:
        if e.code == 429:
            try:
                wait = int(e.headers.get("Retry-After", ""))
            except ValueError:
                wait = 0
            entry["retryAt"] = now + min(max(wait, MIN_INTERVAL_S), 86400)
            entry["error"] = f"Abfrage pausiert (Rate-Limit) · wieder ab {hhmm(entry['retryAt'])}"
        else:
            entry["error"] = f"Anmeldung abgelaufen: {claude_command(account)} starten" if e.code == 401 else f"Server antwortet mit HTTP {e.code}."
    except Exception as e:
        entry["error"] = f"Offline ({type(e).__name__})"
    save_entry(account, entry)
    return entry.get("info"), entry["error"]


def load_prices():
    try:
        with open(f"{HERE}/../../Sources/TokenStats/Resources/pricing.json") as f:
            d = json.load(f)
        return d["models"], d["asOf"]
    except (OSError, ValueError, KeyError):
        return {}, None


PRICES, PRICES_AS_OF = load_prices()


def price_for(model):
    if model in PRICES:
        return PRICES[model]
    undated = re.sub(r"-\d{8}$", "", model)
    if undated in PRICES:
        return PRICES[undated]
    pre = [k for k in PRICES if model.startswith(k)]
    return PRICES[max(pre, key=len)] if pre else None


def model_name(model):
    name = re.sub(r"-\d{8}$", "", model)
    if name.startswith("claude-"):
        parts = name[7:].split("-")
        return parts[0].title() + (" " + ".".join(parts[1:]) if parts[1:] else "")
    return model


# file -> (mtime, size, {msg_id: (day, model, in, out, cache_read, cw5m, cw1h)})
_file_cache = {}


def _scan(path):
    msgs = {}
    with open(path, errors="replace") as f:
        for line in f:
            if '"usage"' not in line:
                continue
            try:
                e = json.loads(line)
                m = e["message"]; u = m["usage"]
                day = datetime.fromisoformat(e["timestamp"].replace("Z", "+00:00")).astimezone().date()
            except (KeyError, ValueError, TypeError):
                continue
            cc = u.get("cache_creation") or {}
            w1 = cc.get("ephemeral_1h_input_tokens", 0)
            w5 = cc.get("ephemeral_5m_input_tokens", u.get("cache_creation_input_tokens", 0) - w1)
            # streaming writes several lines per message id; the last one is the final count
            msgs[m.get("id") or e.get("uuid")] = (
                day, m.get("model", "?"), u.get("input_tokens", 0), u.get("output_tokens", 0),
                u.get("cache_read_input_tokens", 0), w5, w1)
    return msgs


def log_files(accounts):
    """JSONL-Dateien aller Konten; ein per Symlink geteilter projects-Ordner und dieselbe Datei nur einmal."""
    roots, files = set(), {}
    for account in accounts:
        root = os.path.realpath(f"{account['dir']}/projects")
        if root in roots:
            continue
        roots.add(root)
        for path in glob.glob(f"{root}/**/*.jsonl", recursive=True):
            files.setdefault(os.path.realpath(path), path)
    return list(files.values())


def collect_usage(accounts, days=31):
    """-> {day: {model: [in, out, cache_read, cw5m, cw1h]}}"""
    today = datetime.now().astimezone().date()
    since = today - timedelta(days=days - 1)
    out = defaultdict(lambda: defaultdict(lambda: [0, 0, 0, 0, 0]))
    seen = set()
    for path in log_files(accounts):
        st = os.stat(path)
        if datetime.fromtimestamp(st.st_mtime).date() < since:
            continue
        c = _file_cache.get(path)
        if not c or c[:2] != (st.st_mtime, st.st_size):
            c = (st.st_mtime, st.st_size, _scan(path))
            _file_cache[path] = c
        for mid, (day, model, *counts) in c[2].items():
            if day < since or mid in seen or model == "<synthetic>":
                continue
            seen.add(mid)
            acc = out[day][model]
            for i, n in enumerate(counts):
                acc[i] += n
    return out


def value_of(counts, model):
    p = price_for(model)
    if not p:
        return None
    i, o, cr, w5, w1 = counts
    return (i * p["input"] + o * p["output"] + cr * p["cacheRead"]
            + w5 * p["cacheWrite5m"] + w1 * p["cacheWrite1h"])


def fmt(n):
    return f"{n / 1e6:.1f} M" if n >= 1e6 else f"{n / 1e3:.0f} k" if n >= 1e3 else str(n)


def until(iso):
    secs = int((datetime.fromisoformat(iso) - datetime.now(timezone.utc)).total_seconds())
    return max(secs, 0)


def dur(secs):
    d, r = divmod(int(secs), 86400); h, r = divmod(r, 3600)
    if d:
        return f"{d} d" if not h else f"{d} d {h} h"
    return f"{h} h {r // 60} min" if h else f"{r // 60} min"


# ---------- widgets ----------

def color_for(pct):
    return RED if pct >= 100 else YELLOW if pct >= 80 else GREEN


def rgb(hexcolor):
    return tuple(int(hexcolor[i:i + 2], 16) / 255 for i in (1, 3, 5))


def rounded(cr, x, y, w, h, r):
    r = min(r, w / 2, h / 2)
    cr.new_sub_path()
    cr.arc(x + w - r, y + r, r, -1.5708, 0); cr.arc(x + w - r, y + h - r, r, 0, 1.5708)
    cr.arc(x + r, y + h - r, r, 1.5708, 3.1416); cr.arc(x + r, y + r, r, 3.1416, 4.7124)
    cr.close_path()


class Meter(Gtk.DrawingArea):
    """Progress bar with pace mark; hatched area = gap between used share and elapsed share."""

    def __init__(self, pct, elapsed):
        super().__init__()
        self.pct, self.elapsed = pct, elapsed
        self.set_size_request(-1, 16)
        self.connect("draw", self.on_draw)

    def on_draw(self, _w, cr):
        w, h = self.get_allocated_width(), self.get_allocated_height()
        col = color_for(self.pct)
        used = min(self.pct, 100) / 100 * w
        pace = None if self.elapsed is None else min(max(self.elapsed, 0), 1) * w
        rounded(cr, 0, 0, w, h, h / 2)
        cr.clip()
        cr.set_source_rgb(0.2, 0.2, 0.2); cr.paint()
        cr.set_source_rgb(*col); cr.rectangle(0, 0, used, h); cr.fill()
        if pace is not None:
            a, b = sorted((used, pace))
            cr.save()
            cr.rectangle(a, 0, b - a, h); cr.clip()
            cr.set_source_rgba(*col, 0.55); cr.set_line_width(2)
            for x in range(int(a) - h, int(b) + h, 5):
                cr.move_to(x, h); cr.line_to(x + h, 0)
            cr.stroke()
            cr.restore()
            cr.set_source_rgba(1, 1, 1, 0.6); cr.rectangle(pace - 1, 0, 2, h); cr.fill()


class BarChart(Gtk.DrawingArea):
    def __init__(self, series):  # [(label, value, is_last)]
        super().__init__()
        self.series = series
        self.set_size_request(-1, 110)
        self.connect("draw", self.on_draw)

    def on_draw(self, _w, cr):
        w, h = self.get_allocated_width(), self.get_allocated_height()
        n = len(self.series)
        if not n:
            return
        top = max((v for _, v, _ in self.series), default=0) or 1
        gap = 6 if n <= 12 else 2
        bw = (w - gap * (n - 1)) / n
        ch = h - 20
        every = 1 if n <= 8 else max(1, n // 7)
        cr.select_font_face("sans-serif"); cr.set_font_size(11)
        for i, (label, v, last) in enumerate(self.series):
            x = i * (bw + gap)
            bh = v / top * ch
            cr.set_source_rgb(*(BLUE if last else BLUE_DIM))
            rounded(cr, x, ch - bh, bw, bh, 3); cr.fill()
            if label and (i % every == 0 or last):
                cr.set_source_rgb(*((1, 1, 1) if last else (0.6, 0.6, 0.6)))
                ext = cr.text_extents(label)
                cr.move_to(x + (bw - ext.width) / 2, h - 4); cr.show_text(label)


def label(text, css=None, xalign=0, wrap=False):
    l = Gtk.Label(label=text, xalign=xalign)
    l.set_line_wrap(wrap)
    if wrap:   # nichts kürzen: lange Wörter und Pfade brechen notfalls mitten im Wort um
        l.set_line_wrap_mode(Pango.WrapMode.WORD_CHAR)
    for c in (css or "").split():
        l.get_style_context().add_class(c)
    return l


class CommandLabel(Gtk.Label):
    """Befehl in Monospace, mit wrap_command auf die zugeteilte Breite umgebrochen: nie abgeschnitten, nie
    breiter als verfügbar. Die Höhe für eine Breite rechnet das Label selbst (Zeichenbreite per Pango-Layout);
    nach dem Zuteilen der Breite setzt es den umgebrochenen Text."""
    MIN_CHARS = 12

    def __init__(self, command, css="ts-dim"):
        super().__init__(xalign=0)
        self.command, self.max_chars = command, None
        for c in f"{css} ts-mono".split():
            self.get_style_context().add_class(c)
        self.set_text(" ".join(command.split()))
        self.connect("size-allocate", self.on_allocate)

    def char_width(self):
        return self.create_pango_layout("0" * 20).get_pixel_size()[0] / 20 or 8

    def lines_for(self, width):
        return wrap_command(self.command, max(1, int(width // self.char_width())))

    def do_get_request_mode(self):
        return Gtk.SizeRequestMode.HEIGHT_FOR_WIDTH

    def do_get_preferred_width(self):
        return command_label_widths(self.char_width(), self.command, self.MIN_CHARS)

    def do_get_preferred_height_for_width(self, width):
        height = self.create_pango_layout("\n".join(self.lines_for(width))).get_pixel_size()[1]
        return height, height

    def do_get_preferred_height(self):
        return self.do_get_preferred_height_for_width(self.do_get_preferred_width()[0])

    def on_allocate(self, _widget, allocation):
        max_chars = max(1, int(allocation.width // self.char_width()))
        if max_chars != self.max_chars:
            self.max_chars = max_chars
            # nicht mitten in der Größenzuteilung neu setzen; die Höhe dafür ist schon eingeplant
            GLib.idle_add(self.set_text, "\n".join(wrap_command(self.command, max_chars)))


def parts_box(parts, css="ts-dim"):
    """Satzteile umbrechend, kurze Befehle im Satz in Monospace (inline_parts), längere je auf eigenen Zeilen,
    siehe CommandLabel."""
    box = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=4)
    for part in inline_parts(parts):
        if part["kind"] == "cmd":
            widget = CommandLabel(part["text"], css)
        else:
            widget = label(part["text"], css, wrap=True)
            if any(seg["mono"] for seg in part["segments"]):
                widget.set_markup(segments_markup(part["segments"]))
        box.pack_start(widget, False, False, 0)
    return box


def markup(l, color):
    l.set_markup(f'<span foreground="{color}">{GLib.markup_escape_text(l.get_text())}</span>')
    return l


def hexc(c):
    return "#%02x%02x%02x" % tuple(int(x * 255) for x in c)


class Popup(Gtk.Window):
    def __init__(self, app):
        super().__init__(title="Token Stats")
        self.app = app
        self.get_style_context().add_class("ts")
        self.set_default_size(WIDTH, HEIGHT)
        self.set_resizable(False)
        self.set_decorated(False)
        self.connect("delete-event", lambda *_: self.hide() or True)
        self.connect("key-press-event", lambda _w, e: e.keyval == Gdk.KEY_Escape and self.hide())
        self.connect("focus-out-event", self.on_focus_out)
        self.shown_at = 0
        if LayerShell:
            LayerShell.init_for_window(self)
            LayerShell.set_layer(self, LayerShell.Layer.TOP)
            LayerShell.set_namespace(self, "tokenstats")
            LayerShell.set_keyboard_mode(self, LayerShell.KeyboardMode.ON_DEMAND)
        self.page, self.range = "limits", "7d"
        outer = Gtk.Box(orientation=Gtk.Orientation.VERTICAL)
        # Feste Breite 400 (Fenster nicht veränderbar): Kein Inhalt verlangt mehr Mindestbreite, Texte, Kontoleiste
        # und Befehle (CommandLabel) brechen um, statt überzulaufen.
        outer.set_size_request(WIDTH, HEIGHT)
        self.add(outer)

        head = Gtk.Box(spacing=8, margin=16)
        head.pack_start(label("Token Stats", "ts-title"), True, True, 0)
        seg = Gtk.Box(spacing=2)
        self.page_btns = {}
        for key, text in (("limits", "Limits"), ("usage", "Verbrauch")):
            b = Gtk.ToggleButton(label=text); b.get_style_context().add_class("ts-seg")
            b.connect("clicked", self.on_page, key); seg.pack_start(b, False, False, 0)
            self.page_btns[key] = b
        head.pack_end(seg, False, False, 0)
        outer.pack_start(head, False, False, 0)

        # Anbieter-Leiste: ein fester Eintrag „Claude“ auf beiden Seiten, der Punkt zeigt das knappste Konto
        tabs = Gtk.Box(margin_left=10)
        self.provider_tab = Gtk.ToggleButton(); self.provider_tab.get_style_context().add_class("ts-tab")
        self.provider_label = Gtk.Label(label="● Claude")
        self.provider_tab.add(self.provider_label)
        self.provider_tab.set_active(True)
        self.provider_tab.connect("toggled", lambda b: b.get_active() or b.set_active(True))
        tabs.pack_start(self.provider_tab, False, False, 0)
        outer.pack_start(tabs, False, False, 0)
        # Kontoleiste: nur auf „Limits“ und ab zwei Konten; bricht um, statt das Fenster zu verbreitern
        self.account_bar = Gtk.FlowBox(margin_left=16, margin_right=16, margin_top=4, margin_bottom=10)
        self.account_bar.set_selection_mode(Gtk.SelectionMode.NONE)
        self.account_bar.set_homogeneous(False)
        self.account_bar.set_min_children_per_line(1)
        self.account_bar.set_max_children_per_line(64)
        self.account_bar.set_row_spacing(6); self.account_bar.set_column_spacing(6)
        # Volle Breite (FILL), sonst bekommt die FlowBox nur die Breite eines Chips und stellt jeden in eine eigene
        # Zeile; die Chips selbst bleiben links bündig (FlowBoxChild und Button mit START)
        self.account_bar.set_halign(Gtk.Align.FILL)
        self.account_bar.set_no_show_all(True)   # Sichtbarkeit steuert render_tabs
        outer.pack_start(self.account_bar, False, False, 0)
        outer.pack_start(Gtk.Separator(), False, False, 0)

        self.body = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, margin=16, spacing=14)
        sw = Gtk.ScrolledWindow(); sw.set_policy(Gtk.PolicyType.NEVER, Gtk.PolicyType.AUTOMATIC)
        sw.add(self.body)
        outer.pack_start(sw, True, True, 0)

        foot = Gtk.Box(spacing=8); foot.get_style_context().add_class("ts-foot")
        self.status = Gtk.Box(orientation=Gtk.Orientation.VERTICAL)   # Stand und Hinweis, siehe render()
        foot.pack_start(self.status, True, True, 0)
        rb = Gtk.Button(label="⟳"); rb.connect("clicked", lambda *_: app.refresh())
        foot.pack_end(rb, False, False, 0)
        qb = Gtk.Button(label="Beenden"); qb.connect("clicked", lambda *_: Gtk.main_quit())
        foot.pack_end(qb, False, False, 0)
        outer.pack_end(foot, False, False, 0)
        self.page_btns["limits"].set_active(True)

    def on_focus_out(self, *_):
        # ignore the focus flicker right after opening
        if GLib.get_monotonic_time() - self.shown_at > 500_000:
            self.hide()

    def show_at(self, x, y):
        """Open centred above (or below) the tray icon at screen position x, y."""
        self.render()
        self.show_all()
        self.shown_at = GLib.get_monotonic_time()
        if LayerShell:
            mon = Gdk.Display.get_default().get_monitor(0)
            geo = mon.get_geometry()
            w, h = self.get_size()
            from_top = y < geo.height / 2
            for edge, on in ((LayerShell.Edge.LEFT, True), (LayerShell.Edge.TOP, from_top),
                             (LayerShell.Edge.BOTTOM, not from_top), (LayerShell.Edge.RIGHT, False)):
                LayerShell.set_anchor(self, edge, on)
            LayerShell.set_margin(self, LayerShell.Edge.LEFT, int(min(max(x - w / 2, 8), geo.width - w - 8)))
            LayerShell.set_margin(self, LayerShell.Edge.TOP if from_top else LayerShell.Edge.BOTTOM, 8)
        self.present()

    def on_page(self, btn, key):
        if not btn.get_active():
            if self.page == key:
                btn.set_active(True)
            return
        self.page = key
        for k, b in self.page_btns.items():
            if k != key:
                b.set_active(False)
        self.render()

    def on_range(self, btn, key):
        if btn.get_active() and self.range != key:
            self.range = key
            self.render()

    def on_account(self, _btn, account_id):
        if self.app.current_id != account_id:
            self.app.current_id = account_id
            GLib.idle_add(self.render)   # nicht im Klick des Knopfs, den render() gleich ersetzt

    def account_chip(self, account, selected):
        """Knopf der Kontoleiste: Zustandspunkt und Bezeichnung (ungekürzt), Fehlerkonto grau mit „!“."""
        problem, pct = account["problem"], account["pct"]
        box = Gtk.Box(spacing=6)
        box.pack_start(markup(label("●"), hexc(GREY if problem or pct is None else color_for(pct))), False, False, 0)
        box.pack_start(label(account["label"], wrap=True), False, False, 0)
        if problem:
            box.pack_start(label("!", "ts-bold"), False, False, 0)
        button = Gtk.Button(halign=Gtk.Align.START)
        button.add(box)
        ctx = button.get_style_context()
        ctx.add_class("ts-acc")
        if selected:
            ctx.add_class("ts-sel")
        if problem:
            ctx.add_class("ts-problem")
        button.connect("clicked", self.on_account, account["id"])
        child = Gtk.FlowBoxChild(halign=Gtk.Align.START)
        child.add(button)
        return child

    def render_tabs(self):
        a = self.app
        tightest = pick_account(a.accounts, None)
        pct = tightest["pct"] if tightest and not tightest["problem"] else None
        self.provider_label.set_markup(f'<span foreground="{hexc(GREY if pct is None else color_for(pct))}">●</span> Claude')
        for c in self.account_bar.get_children():
            c.destroy()
        if self.page == "limits" and len(a.accounts) > 1:
            current = a.account()
            for account in a.accounts:
                chip = self.account_chip(account, account is current)
                chip.show_all()
                self.account_bar.add(chip)
            self.account_bar.show()
        else:
            self.account_bar.hide()

    def render(self):
        for c in self.body.get_children():
            c.destroy()
        a = self.app
        self.render_tabs()
        account = a.account()
        warning = footer_note(self.page, account, a.note)
        stand = f"Stand {a.updated:%H:%M}" if a.updated else "lädt …"
        for c in self.status.get_children():
            c.destroy()
        parts = text_parts(warning)
        status = parts_box(prefixed(f"{stand}  ·  ⚠", parts) if parts else [{"kind": "text", "text": stand}])
        status.show_all()
        self.status.pack_start(status, False, False, 0)
        if a.updated and not a.accounts:
            self.render_empty()
        else:
            (self.render_limits if self.page == "limits" else self.render_usage)()
        self.body.show_all()

    def render_empty(self):
        self.body.pack_start(label(EMPTY_TITLE, "ts-h", wrap=True), False, False, 0)
        self.body.pack_start(parts_box(EMPTY_PARTS), False, False, 0)

    def render_limits(self):
        account = self.app.account()
        if account and account["state"] == MISSING_FOLDER:
            self.body.pack_start(label(account["title"], "ts-h", wrap=True), False, False, 0)
            # Pfad wie in den Einstellungen auf macOS und Windows: eigene Zeile in Monospace, bricht wie ein Befehl um
            self.body.pack_start(CommandLabel(account["folder"]), False, False, 0)
            self.body.pack_start(markup(label(account["missing"], wrap=True), RED_TEXT), False, False, 0)
            self.body.pack_start(label(account["missingHint"], "ts-dim", wrap=True), False, False, 0)
            return
        info = account and account["info"]
        if not info:
            text = account["note"] if account and account["note"] else "Lädt …"
            if account and len(self.app.accounts) > 1:
                self.body.pack_start(label(account["title"], "ts-h", wrap=True), False, False, 0)
            self.body.pack_start(parts_box(text_parts(text)), False, False, 0)
            return
        worst = max((r["pct"] for r in info["limits"]), default=0)
        h = Gtk.Box(spacing=8)
        h.pack_start(label(account["title"], "ts-h", wrap=True), False, False, 0)   # darf zweizeilig werden
        h.pack_start(label(info["plan"], "ts-dim ts-mono"), False, False, 0)
        pill = markup(label(f"{worst:.0f} %", "ts-pill"), hexc(color_for(worst)))
        h.pack_end(pill, False, False, 0)
        self.body.pack_start(h, False, False, 0)
        for r in info["limits"]:
            box = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=4)
            top = Gtk.Box(spacing=8)
            top.pack_start(label(r["title"], "ts-h"), False, False, 0)
            top.pack_start(label(r["sub"], "ts-dim"), False, False, 0)
            top.pack_end(markup(label(f"{r['pct']:.0f} %", "ts-h"), hexc(color_for(r["pct"]))), False, False, 0)
            box.pack_start(top, False, False, 0)
            left = until(r["reset"]) if r["reset"] else None
            elapsed = None if left is None else 1 - left / r["window"]
            box.pack_start(Meter(r["pct"], elapsed), False, False, 2)
            bottom = Gtk.Box()
            reset_txt = ""
            if r["reset"]:
                rt = datetime.fromisoformat(r["reset"]).astimezone()
                fmt_t = "%H:%M" if left < 86400 else "%a %H:%M"
                reset_txt = f"Reset {rt.strftime(fmt_t)}"
            bottom.pack_start(label(reset_txt, "ts-dim"), False, False, 0)
            if elapsed is not None:
                gap = (r["pct"] / 100 - elapsed) * r["window"]
                if abs(gap) < r["window"] * 0.02:
                    txt, col = "im Takt", None
                elif gap > 0:
                    txt, col = f"{dur(gap)} vorgegriffen", hexc(color_for(r["pct"]))
                else:
                    txt, col = f"{dur(-gap)} ungenutzt", hexc(color_for(r["pct"]))
                l = label(txt, "ts-dim")
                bottom.pack_end(markup(l, col) if col else l, False, False, 0)
            box.pack_start(bottom, False, False, 0)
            self.body.pack_start(box, False, False, 4)
        if info["extra"]:
            self.body.pack_start(Gtk.Separator(), False, False, 0)
            chip = label(info["extra"], "ts-chip")
            row = Gtk.Box(); row.pack_start(chip, False, False, 0)
            self.body.pack_start(row, False, False, 0)

    def render_usage(self):
        usage = self.app.usage
        today = datetime.now().astimezone().date()
        # gezählt werden die Konten, deren Protokolle eingelesen werden (ohne fehlende Ordner)
        accounts = [a for a in self.app.accounts if a["state"] == OK]
        info = accounts[0]["info"] if accounts else None
        h = Gtk.Box(spacing=8)
        h.pack_start(label("Claude", "ts-h"), False, False, 0)
        if len(accounts) > 1:
            h.pack_start(label(f"{len(accounts)} Konten", "ts-dim ts-mono"), False, False, 0)
        elif info:
            h.pack_start(label(info["plan"], "ts-dim ts-mono"), False, False, 0)
        self.body.pack_start(h, False, False, 0)

        ranges = [("1d", "Heute", 1), ("7d", "7 Tage", 7), ("30d", "30 Tage", 30), ("month", "Monat", None)]
        rbox = Gtk.Box(spacing=4)
        for key, text, _ in ranges:
            b = Gtk.ToggleButton(label=text); b.set_active(key == self.range)
            b.get_style_context().add_class("ts-range"); b.connect("toggled", self.on_range, key)
            rbox.pack_start(b, False, False, 0)
        self.body.pack_start(rbox, False, False, 0)

        n = {"1d": 1, "7d": 7, "30d": 30}.get(self.range) or today.day
        days = [today - timedelta(days=i) for i in range(n - 1, -1, -1)]
        per_model = defaultdict(lambda: [0, 0, 0, 0, 0])
        series, total_val, unpriced = [], 0.0, False
        for d in days:
            day_tokens = 0
            for model, c in usage.get(d, {}).items():
                for i in range(5):
                    per_model[model][i] += c[i]
                day_tokens += sum(c)
            series.append((d.strftime("%a")[:2] if n <= 7 else str(d.day), day_tokens, d == today))
        total = sum(sum(c) for c in per_model.values())
        cache = sum(c[2] + c[3] + c[4] for c in per_model.values())
        for model, c in per_model.items():
            v = value_of(c, model)
            if v is None:
                unpriced = True
            else:
                total_val += v

        cards = Gtk.Box(spacing=10, homogeneous=True)
        for title, big, small in (("TOKENS", fmt(total), f"{fmt(cache)} davon Cache"),
                                  ("API-VERGLEICHSWERT", f"{total_val:,.2f} $", "zu Listenpreisen")):
            card = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=2)
            card.get_style_context().add_class("ts-card")
            card.pack_start(label(title, "ts-dim"), False, False, 0)
            card.pack_start(label(big, "ts-big"), False, False, 0)
            card.pack_start(label(small, "ts-dim"), False, False, 0)
            cards.pack_start(card, True, True, 0)
        self.body.pack_start(cards, False, False, 0)
        if n > 1:
            self.body.pack_start(BarChart(series), False, False, 4)

        for model, c in sorted(per_model.items(), key=lambda kv: -sum(kv[1])):
            v = value_of(c, model)
            row = Gtk.Box(orientation=Gtk.Orientation.VERTICAL)
            top = Gtk.Box()
            top.pack_start(label(model_name(model), "ts-h"), False, False, 0)
            top.pack_end(label(f"{v:,.2f} $" if v is not None else "k. A.", "ts-h"), False, False, 0)
            row.pack_start(top, False, False, 0)
            row.pack_start(label(f"{fmt(c[0])} Input · {fmt(c[1])} Output · {fmt(c[2] + c[3] + c[4])} Cache", "ts-dim"),
                           False, False, 0)
            self.body.pack_start(row, False, False, 0)
            self.body.pack_start(Gtk.Separator(), False, False, 0)
        tot = Gtk.Box()
        tot.pack_start(label(f"{n} Tage · {fmt(total)} Tokens" if n > 1 else f"Heute · {fmt(total)} Tokens", "ts-h"),
                       False, False, 0)
        tot.pack_end(label(f"{total_val:,.2f} $", "ts-h"), False, False, 0)
        self.body.pack_start(tot, False, False, 0)
        asof = f" (Stand {PRICES_AS_OF})" if PRICES_AS_OF else ""
        source = (f"aller {len(accounts)} Konten zusammen (die Protokolle nennen kein Konto)"
                  if len(accounts) > 1 else "")
        foot = ("Lokal gezählte Tokens aus den Sitzungsprotokollen " + (source + " " if source else "")
                + "× Listenpreis" + asof + ", inkl. Cache-Tarife. "
                "Keine Abrechnungsdaten – nur, was derselbe Verbrauch über die API gekostet hätte."
                + (" Modelle ohne Listenpreis sind nicht eingerechnet." if unpriced else ""))
        self.body.pack_start(label(foot, "ts-dim", wrap=True), False, False, 0)


# ---------- tray (StatusNotifierItem, so a left click calls Activate with the icon position) ----------

SNI_XML = """<node><interface name="org.kde.StatusNotifierItem">
<method name="Activate"><arg type="i" direction="in"/><arg type="i" direction="in"/></method>
<method name="SecondaryActivate"><arg type="i" direction="in"/><arg type="i" direction="in"/></method>
<method name="ContextMenu"><arg type="i" direction="in"/><arg type="i" direction="in"/></method>
<method name="Scroll"><arg type="i" direction="in"/><arg type="s" direction="in"/></method>
<property name="Category" type="s" access="read"/><property name="Id" type="s" access="read"/>
<property name="Title" type="s" access="read"/><property name="Status" type="s" access="read"/>
<property name="WindowId" type="u" access="read"/><property name="IconName" type="s" access="read"/>
<property name="IconPixmap" type="a(iiay)" access="read"/><property name="OverlayIconName" type="s" access="read"/>
<property name="AttentionIconName" type="s" access="read"/><property name="ItemIsMenu" type="b" access="read"/>
<property name="Menu" type="o" access="read"/><property name="ToolTip" type="(sa(iiay)ss)" access="read"/>
<signal name="NewIcon"/><signal name="NewToolTip"/><signal name="NewStatus"><arg type="s"/></signal>
</interface></node>"""


def render_icon(pct, size=32):
    """Ring in the state colour with the percentage inside, as ARGB32 bytes in network order."""
    surf = cairo.ImageSurface(cairo.FORMAT_ARGB32, size, size)
    cr = cairo.Context(surf)
    c, r, lw = size / 2, size / 2 - 3, 3.5
    cr.set_line_width(lw)
    cr.set_source_rgba(0.6, 0.6, 0.6, 0.45); cr.arc(c, c, r, 0, 6.2832); cr.stroke()
    cr.set_source_rgb(*color_for(pct))
    cr.arc(c, c, r, -1.5708, -1.5708 + min(pct, 100) / 100 * 6.2832); cr.stroke()
    cr.select_font_face("sans-serif", cairo.FONT_SLANT_NORMAL, cairo.FONT_WEIGHT_BOLD)
    cr.set_font_size(12 if pct < 100 else 10)
    cr.set_source_rgb(0.92, 0.92, 0.92)
    txt = f"{pct:.0f}"
    ext = cr.text_extents(txt)
    cr.move_to(c - ext.width / 2 - ext.x_bearing, c - ext.height / 2 - ext.y_bearing); cr.show_text(txt)
    raw = bytearray(surf.get_data())  # native little-endian BGRA -> ARGB
    out = bytearray(len(raw))
    out[0::4], out[1::4], out[2::4], out[3::4] = raw[3::4], raw[2::4], raw[1::4], raw[0::4]
    return size, size, bytes(out)


def display_scale():
    """Fractional scale of the first output (GTK only reports the rounded-up integer)."""
    try:
        out = subprocess.run(["kscreen-doctor", "-j"], capture_output=True, text=True, timeout=5).stdout
        return float(next(o["scale"] for o in json.loads(out)["outputs"] if o.get("enabled")))
    except (OSError, ValueError, StopIteration, KeyError, subprocess.SubprocessError):
        return 1.0


class Tray:
    PATH = "/StatusNotifierItem"

    def __init__(self, on_activate):
        self.on_activate, self.pixmap = on_activate, render_icon(0)
        self.last_activate, self.scale = 0, display_scale()
        self.conn = Gio.bus_get_sync(Gio.BusType.SESSION, None)
        self.name = f"org.kde.StatusNotifierItem-{os.getpid()}-1"
        Gio.bus_own_name_on_connection(self.conn, self.name, Gio.BusNameOwnerFlags.NONE, None, None)
        info = Gio.DBusNodeInfo.new_for_xml(SNI_XML).interfaces[0]
        self.conn.register_object(self.PATH, info, self.on_call, self.on_get, None)
        self.conn.call_sync("org.kde.StatusNotifierWatcher", "/StatusNotifierWatcher",
                            "org.kde.StatusNotifierWatcher", "RegisterStatusNotifierItem",
                            GLib.Variant("(s)", (self.name,)), None, Gio.DBusCallFlags.NONE, 3000, None)

    def on_call(self, _c, _sender, _path, _iface, method, params, inv):
        if method == "Activate":
            x, y = params.unpack()
            # Plasma sends the icon centre in physical pixels, and twice per click
            now = GLib.get_monotonic_time()
            if now - self.last_activate < 400_000:
                inv.return_value(None)
                return
            self.last_activate = now
            x, y = x / self.scale, y / self.scale
            GLib.idle_add(self.on_activate, x, y)
        inv.return_value(None)

    def on_get(self, _c, _sender, _path, _iface, prop):
        w, h, data = self.pixmap
        return {
            "Category": GLib.Variant("s", "ApplicationStatus"), "Id": GLib.Variant("s", "tokenstats"),
            "Title": GLib.Variant("s", "Token Stats"), "Status": GLib.Variant("s", "Active"),
            "WindowId": GLib.Variant("u", 0), "IconName": GLib.Variant("s", ""),
            "IconPixmap": GLib.Variant("a(iiay)", [(w, h, list(data))]),
            "OverlayIconName": GLib.Variant("s", ""), "AttentionIconName": GLib.Variant("s", ""),
            "ItemIsMenu": GLib.Variant("b", False), "Menu": GLib.Variant("o", "/NO_DBUSMENU"),
            "ToolTip": GLib.Variant("(sa(iiay)ss)", ("", [], "Token Stats", "")),
        }.get(prop)

    def set_percent(self, pct):
        self.pixmap = render_icon(pct)
        self.conn.emit_signal(None, self.PATH, "org.kde.StatusNotifierItem", "NewIcon", None)


class App:
    def __init__(self):
        prov = Gtk.CssProvider(); prov.load_from_data(CSS)
        Gtk.StyleContext.add_provider_for_screen(Gdk.Screen.get_default(), prov,
                                                 Gtk.STYLE_PROVIDER_PRIORITY_APPLICATION)
        # accounts: [account_view(...)], current_id: gewähltes Konto auf „Limits“ (None = das knappste)
        self.accounts, self.current_id, self.usage, self.note, self.updated = [], None, {}, "", None
        self.popup = Popup(self)
        self.tray = Tray(self.toggle)
        self.refresh()
        GLib.timeout_add_seconds(INTERVAL_S + 5, self.refresh)   # knapp über dem 300-s-Minimum

    def toggle(self, x=0, y=10 ** 6):
        if self.popup.get_visible():
            self.popup.hide()
        else:
            self.current_id = tightest_id(self.accounts)   # beim Öffnen ist das knappste Konto gewählt
            self.popup.show_at(x, y)
        return False

    def refresh(self, *_):
        threading.Thread(target=self._work, daemon=True).start()
        return True

    def account(self):
        return pick_account(self.accounts, self.current_id)

    def _work(self):
        found = discover_accounts()
        accounts = [account_view(account, *limits_with_cache(account), len(found)) for account in found]
        note = ""
        try:
            usage = collect_usage([account for account in found if account["state"] == OK])
        except Exception as e:
            usage, note = self.usage, f"Verbrauch: {type(e).__name__}"
        GLib.idle_add(self._apply, accounts, usage, note)

    def _apply(self, accounts, usage, note):
        # Auswahl über die Konto-ID halten; fällt das Konto weg (oder war noch keins da), das knappste
        self.accounts, self.usage, self.note = accounts, usage, note
        if not any(a["id"] == self.current_id for a in accounts):
            self.current_id = tightest_id(accounts)
        self.updated = datetime.now()
        worst = max((r["pct"] for a in accounts if a["info"] for r in a["info"]["limits"]), default=0)
        self.tray.set_percent(worst)
        if self.popup.get_visible():
            self.popup.render()


if __name__ == "__main__":
    App()
    Gtk.main()
