#!/usr/bin/env python3
"""Data source for the Token Stats plasmoid: prints one JSON document to stdout.

Limits come from api.anthropic.com/api/oauth/usage (login from ~/.claude/.credentials.json, read only),
token counts from ~/.claude/projects/**/*.jsonl, prices from pricing.json (next to this file once installed, otherwise
Sources/TokenStats/Resources/pricing.json of the checkout).

Several accounts (SPEC §6 „Mehrere Konten je Anbieter“): every CLAUDE_CONFIG_DIR is an account of its own —
~/.claude-* and ~/.claude_* with a .claude.json are found automatically, further folders come from
TOKENSTATS_CLAUDE_DIRS (separated by ":"). Limits per account, usage over the logs of all accounts.
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
        account = json.load(open(path)).get("oauthAccount")
    except (OSError, ValueError, AttributeError):
        return {}
    return account if isinstance(account, dict) else {}


def discover_accounts():
    """-> [{id, folder, dir, label}]: Standardkonto ~/.claude, dann ~/.claude-*/~/.claude_* mit .claude.json,
    CLAUDE_CONFIG_DIR und TOKENSTATS_CLAUDE_DIRS. Derselbe Ordner und dieselbe Anmeldung (accountUuid) nur einmal."""
    try:
        names = sorted(n for n in os.listdir(HOME) if n.startswith((".claude-", ".claude_")))
    except OSError:
        names = []
    folders = [None] + [f"{HOME}/{n}" for n in names
                        if os.path.isdir(f"{HOME}/{n}") and os.path.isfile(f"{HOME}/{n}/.claude.json")]
    for extra in [os.environ.get("CLAUDE_CONFIG_DIR", "")] + os.environ.get(CLAUDE_DIRS_ENV, "").split(":"):
        if extra:
            folders.append(os.path.abspath(os.path.expanduser(extra)).rstrip("/"))
    accounts, real_seen, uuid_seen = [], set(), set()
    for folder in folders:
        path = folder or f"{HOME}/.claude"
        real = os.path.realpath(path)
        if real in real_seen or (folder and not os.path.isdir(path)):
            continue
        real_seen.add(real)
        account = read_account(f"{folder}/.claude.json" if folder else f"{HOME}/.claude.json")
        uuid = account.get("accountUuid")
        if uuid in uuid_seen:
            continue   # zweimal dieselbe Anmeldung: sonst doppelte Abfragen gegen dasselbe Rate-Limit
        if uuid:
            uuid_seen.add(uuid)
        email, name = account.get("emailAddress") or "", account.get("displayName") or ""
        label = email.split("@")[0] or name or (os.path.basename(folder).lstrip(".") if folder else "Standard")
        accounts.append({"id": f"claude@{folder_hash(folder)}" if folder else "claude",
                         "folder": folder, "dir": path, "label": label})
    return accounts


def claude_command(account, args=""):
    """Befehl für Hinweise: beim zweiten Konto mit Ordner, ein schlichtes `claude` erneuert nur das Standardkonto."""
    prefix = f"CLAUDE_CONFIG_DIR={short_path(account['folder'])} " if account["folder"] else ""
    return f"`{prefix}claude{args}`"


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
            d = json.load(open(path))
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
        d = json.load(open(LIMITS_CACHE))
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
            entry["error"] = f"Anmeldung abgelaufen: {claude_command(account)} starten" if e.code == 401 else f"HTTP {e.code}"
    except Exception as e:
        entry["error"] = f"Offline ({type(e).__name__})"
    save_entry(account, entry)
    return entry.get("info"), entry["error"]


def main():
    """Ein Eintrag je Konto unter „accounts“; „title“ ist „Claude“ oder bei mehreren Konten „Claude · frank“."""
    result = {"error": None, "priceDate": PRICES_AS_OF, "accounts": []}
    accounts = discover_accounts()
    for account in accounts:
        info, error = limits_with_cache(account)
        title = f"Claude · {account['label']}" if len(accounts) > 1 else "Claude"
        result["accounts"].append({"id": account["id"], "label": account["label"], "title": title, "error": error,
                                   **(info or {"plan": "", "limits": [], "extra": None})})
    try:
        result["usage"] = collect_usage(accounts)
    except Exception as e:
        result["usage"] = []
        result["error"] = f"Verbrauch: {type(e).__name__}"
    json.dump(result, sys.stdout)


if __name__ == "__main__":
    main()
