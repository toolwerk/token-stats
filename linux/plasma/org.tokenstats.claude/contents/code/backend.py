#!/usr/bin/env python3
"""Data source for the Token Stats plasmoid: prints one JSON document to stdout.

Limits come from api.anthropic.com/api/oauth/usage (login from ~/.claude/.credentials.json, read only),
token counts from ~/.claude/projects/**/*.jsonl, prices from pricing.json (next to this file once installed, otherwise
Sources/TokenStats/Resources/pricing.json of the checkout).

Several accounts (SPEC §6 „Mehrere Konten je Anbieter“): every CLAUDE_CONFIG_DIR is an account of its own —
~/.claude-* and ~/.claude_* with a .claude.json are found automatically, further folders come from
TOKENSTATS_CLAUDE_DIRS (separated by ":"). Limits per account, usage over the logs of all accounts.
A folder from CLAUDE_CONFIG_DIR or TOKENSTATS_CLAUDE_DIRS that does not exist stays in the list as
"missingFolder" (grey with "!" in the account bar) and is never queried.
"""
import glob, hashlib, json, os, re, sys, time, urllib.error, urllib.request
from datetime import datetime, timedelta

HOME = os.path.expanduser("~")
HERE = os.path.dirname(os.path.abspath(__file__))
CLAUDE_DIRS_ENV = "TOKENSTATS_CLAUDE_DIRS"
CACHE_DIR = f"{HOME}/.cache/tokenstats"
LIMITS_CACHE = f"{CACHE_DIR}/limits.json"
# Der Usage-Endpunkt ist hart rate-limitiert: höchstens eine Abfrage alle 300 s, auch bei Klick auf
# „Aktualisieren“ oder nach einem Neustart. Der Stand liegt im Cache; main.qml fragt alle 305 s.
MIN_INTERVAL_S = 300
WINDOWS = {"session": 5 * 3600, "weekly_all": 7 * 86400, "weekly_scoped": 7 * 86400}

# Zustand eines Kontoeintrags (Textkatalog „Mehrere Konten“, Abschnitt „Modell“)
OK, MISSING_FOLDER = "ok", "missingFolder"
# Wie in den Einstellungen auf macOS und Windows; der Pfad steht darüber auf eigener Zeile (Feld „folder“)
MISSING_FOLDER_TEXT = ("Ordner nicht gefunden. Das Konto steht grau im Menü. "
                       "Ist das Laufwerk eingehängt, wird es wieder abgefragt.")
MISSING_FOLDER_HINT = "Kommt der Ordner aus TOKENSTATS_CLAUDE_DIRS, dort entfernen, wenn es ihn nicht mehr gibt."
NO_INFO = {"plan": "", "limits": [], "extra": None}


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


def plan_label(c):
    m = re.search(r"max_(\d+)x", c.get("rateLimitTier") or "")
    return f"{c.get('subscriptionType', '').title()}{f' {m.group(1)}×' if m else ''}"


# ---------- Konten ----------

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


def account_view(account, info, error, count):
    """Eintrag für die Anzeige. problem = grau mit „!“: Ordner fehlt, oder Abruffehler ohne Stand."""
    missing = account["state"] == MISSING_FOLDER
    return {"id": account["id"], "label": account["label"], "state": account["state"],
            "title": f"Claude · {account['label']}" if count > 1 else "Claude",
            "folder": short_path(account["dir"]) if account["folder"] else None,
            "info": info, "error": error, "errorParts": inline_parts(text_parts(error)), "pct": worst_pct(info),
            "problem": missing or (not info and bool(error)),
            "missing": MISSING_FOLDER_TEXT if missing else None,
            "missingHint": MISSING_FOLDER_HINT if missing else None}


def claude_command(account, args=""):
    """Befehl für Hinweise, in »…« (text_parts macht daraus eine eigene Zeile): beim zweiten Konto mit Ordner,
    ein schlichtes »claude« erneuert nur das Standardkonto."""
    prefix = f"CLAUDE_CONFIG_DIR={short_path(account['folder'])} " if account["folder"] else ""
    return f"»{prefix}claude{args}«"


def load_creds(account):
    return json.load(open(f"{account['dir']}/.credentials.json"))["claudeAiOauth"]


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
    extra_txt = None
    if extra.get("is_enabled"):
        div = 10 ** extra.get("decimal_places", 2)
        cur = {"EUR": "€", "USD": "$"}.get(extra.get("currency"), extra.get("currency", ""))
        extra_txt = f"Extra {extra['used_credits'] / div:,.2f} {cur} / {extra['monthly_limit'] / div:,.2f} {cur}"
    return {"plan": plan_label(c), "limits": rows, "extra": extra_txt}


def load_prices():
    for path in (f"{HERE}/pricing.json", f"{HERE}/../../../../../Sources/TokenStats/Resources/pricing.json"):
        try:
            with open(path) as f:
                d = json.load(f)
            return d["models"], d["asOf"]
        except (OSError, ValueError, KeyError):
            pass
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


def scan(path):
    """-> {msg_id: (day, model, in, out, cache_read, cw5m, cw1h)}"""
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
    today = datetime.now().astimezone().date()
    since = today - timedelta(days=days - 1)
    per_day = {}
    seen = set()
    for path in log_files(accounts):
        if datetime.fromtimestamp(os.stat(path).st_mtime).date() < since:
            continue
        for mid, (day, model, *counts) in scan(path).items():
            if day < since or mid in seen or model == "<synthetic>":
                continue
            seen.add(mid)
            acc = per_day.setdefault(day, {}).setdefault(model, [0, 0, 0, 0, 0])
            for i, n in enumerate(counts):
                acc[i] += n
    out = []
    for day in (today - timedelta(days=i) for i in range(days - 1, -1, -1)):
        models = []
        for model, (i, o, cr, w5, w1) in per_day.get(day, {}).items():
            p = price_for(model)
            value = None if not p else (i * p["input"] + o * p["output"] + cr * p["cacheRead"]
                                        + w5 * p["cacheWrite5m"] + w1 * p["cacheWrite1h"])
            models.append({"model": model_name(model), "in": i, "out": o, "cache": cr + w5 + w1, "value": value})
        out.append({"date": day.isoformat(), "models": models})
    return out


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
        os.makedirs(CACHE_DIR, exist_ok=True)
        tmp = f"{LIMITS_CACHE}.{os.getpid()}.tmp"   # atomar ersetzen, damit kein Leser eine halbe Datei sieht
        with open(tmp, "w") as f:
            json.dump(cache, f)
        os.replace(tmp, LIMITS_CACHE)
    except OSError:
        pass


def hhmm(ts):
    return datetime.fromtimestamp(ts).strftime("%H:%M")


def save_entry(account, entry):
    cache = read_cache()   # frisch lesen: Plasma und GTK schreiben dieselbe Datei
    cache["accounts"][account["id"]] = entry
    write_cache(cache)


def limits_with_cache(account):
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


def main():
    """Ein Eintrag je Konto unter „accounts“ (Felder aus account_view plus Stand), „tightest“ = ID des
    knappsten Kontos (beim Öffnen gewählt), „usageAccounts“ = Zahl der Konten, deren Protokolle zählen,
    „emptyParts“ = Text des leeren Zustands als Satzteile und Befehle (inline_parts)."""
    result = {"error": None, "priceDate": PRICES_AS_OF, "accounts": [], "tightest": None, "usageAccounts": 0,
              "emptyParts": inline_parts(EMPTY_PARTS)}
    accounts = discover_accounts()
    views = [account_view(account, *limits_with_cache(account), len(accounts)) for account in accounts]
    result["tightest"] = tightest_id(views)
    for view in views:
        info = view.pop("info")
        result["accounts"].append({**view, **(info or NO_INFO)})
    usable = [account for account in accounts if account["state"] == OK]
    result["usageAccounts"] = len(usable)
    try:
        result["usage"] = collect_usage(usable)
    except Exception as e:
        result["usage"] = []
        result["error"] = f"Verbrauch: {type(e).__name__}"
    json.dump(result, sys.stdout)


if __name__ == "__main__":
    main()
