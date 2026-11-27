"""Tests der Kontologik beider Linux-Fassungen (Plasma-Backend und GTK), ohne GTK, Qt oder Netz.

Lauf aus dem Repo: python3 -I -m unittest discover -s linux/tests -v

Alle Ordner liegen in einem temporären HOME, alle Namen sind Demo-Werte. Abfragen an den Endpunkt sind
in jedem Test verboten (urlopen und fetch_limits schlagen fehl, falls sie doch aufgerufen werden).
"""
import contextlib
import importlib.util
import io
import json
import os
import random
import shutil
import subprocess
import sys
import tempfile
import unittest
from unittest import mock

LINUX = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
BACKEND = os.path.join(LINUX, "plasma", "org.tokenstats.claude", "contents", "code", "backend.py")
GTK = os.path.join(LINUX, "gtk", "tokenstats.py")

# Texte aus dem Textkatalog „Mehrere Konten“, Abschnitt „Linux“
MISSING_TEXT = ("Ordner nicht gefunden. Das Konto steht grau im Menü. "
                "Ist das Laufwerk eingehängt, wird es wieder abgefragt.")
MISSING_HINT = "Kommt der Ordner aus TOKENSTATS_CLAUDE_DIRS, dort entfernen, wenn es ihn nicht mehr gibt."
EMPTY_TITLE = "Kein Claude-Konto gefunden"
EMPTY_TEXT = "Melde dich mit »claude« an. Weitere Ordner: TOKENSTATS_CLAUDE_DIRS=/pfad/eins:/pfad/zwei"

_IMPORT_HOME = tempfile.mkdtemp(prefix="tokenstats-import-")


def _load(name, path):
    # HOME beim Import auf einen leeren Ordner, damit auch die Cache-Pfade der Module nie ins echte Home zeigen
    with mock.patch.dict(os.environ, {"HOME": _IMPORT_HOME}):
        spec = importlib.util.spec_from_file_location(name, path)
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
    return module


backend = _load("tokenstats_backend", BACKEND)
gtk = _load("tokenstats_gtk", GTK)
MODULES = {"backend": backend, "gtk": gtk}


def tearDownModule():
    shutil.rmtree(_IMPORT_HOME, ignore_errors=True)


def _no_request(*_args, **_kwargs):
    raise AssertionError("Endpunkt darf im Test nicht abgefragt werden")


class Home:
    """Temporäres HOME mit Claude-Ordnern; patcht HOME und Cache-Pfade beider Module."""

    def __init__(self, test):
        self.root = tempfile.mkdtemp(prefix="tokenstats-home-")
        test.addCleanup(shutil.rmtree, self.root, True)
        self.cache = os.path.join(self.root, ".cache", "tokenstats")
        for module in MODULES.values():
            test.enterContext(mock.patch.object(module, "HOME", self.root))
            test.enterContext(mock.patch.object(module, "LIMITS_CACHE", os.path.join(self.cache, "limits.json")))
            test.enterContext(mock.patch.object(module, "fetch_limits", _no_request))
        test.enterContext(mock.patch.object(backend, "CACHE_DIR", self.cache))
        test.enterContext(mock.patch.object(gtk, "ICON_DIR", self.cache))
        test.enterContext(mock.patch("urllib.request.urlopen", _no_request))
        test.enterContext(mock.patch.dict(os.environ, {"HOME": self.root}))
        os.environ.pop("CLAUDE_CONFIG_DIR", None)
        os.environ.pop("TOKENSTATS_CLAUDE_DIRS", None)

    def path(self, name):
        return os.path.join(self.root, name)

    def folder(self, name, email=None, uuid=None, claude_json=True):
        """Konfigurationsordner wie von `CLAUDE_CONFIG_DIR=<ordner> claude`; name relativ zum HOME."""
        path = self.path(name)
        os.makedirs(path, exist_ok=True)
        if claude_json:
            account = {"emailAddress": email, "accountUuid": uuid} if email or uuid else {}
            # Standardkonto: .claude.json liegt neben ~/.claude, sonst im Ordner
            target = self.path(".claude.json") if name == ".claude" else os.path.join(path, ".claude.json")
            with open(target, "w") as f:
                json.dump({"oauthAccount": account}, f)
        return path

    def manual(self, *paths, config_dir=None):
        os.environ["TOKENSTATS_CLAUDE_DIRS"] = ":".join(paths)
        if config_dir is not None:
            os.environ["CLAUDE_CONFIG_DIR"] = config_dir


def sentence(parts):
    """Teile wieder als Satz; Befehle außer dem letzten Teil in »…« wie im Katalog."""
    out = []
    for i, part in enumerate(parts):
        quoted = part["kind"] == "cmd" and i < len(parts) - 1
        out.append(f"»{part['text']}«" if quoted else part["text"])
    return " ".join(out)


def summary(accounts):
    return [(a["label"], a["source"], a["state"]) for a in accounts]


class DiscoveryTest(unittest.TestCase):
    def each(self):
        for name, module in MODULES.items():
            with self.subTest(module=name):
                yield module

    def test_order_default_auto_manual(self):
        home = Home(self)
        home.folder(".claude", email="privat@example.com", uuid="u-privat")
        home.folder(".claude-arbeit", email="arbeit@example.com", uuid="u-arbeit")
        home.folder(".claude-ohne-anmeldung", claude_json=False)   # ohne .claude.json: nicht automatisch
        kunde = home.folder("konten/kunde-a", email="kunde-a@example.com", uuid="u-kunde")
        home.manual(kunde, home.path("usb/claude-fehlt"))
        for module in self.each():
            self.assertEqual(summary(module.discover_accounts()), [
                ("privat", "default", "ok"),
                ("arbeit", "auto", "ok"),
                ("kunde-a", "manual", "ok"),
                ("claude-fehlt", "manual", "missingFolder"),
            ])

    def test_missing_manual_folder_stays_with_stable_id(self):
        home = Home(self)
        home.folder(".claude", email="privat@example.com")
        gone = home.path("usb/claude-arbeit")
        home.manual(gone)
        for module in self.each():
            accounts = module.discover_accounts()
            self.assertEqual(len(accounts), 2)
            missing = accounts[1]
            self.assertEqual(missing["state"], "missingFolder")
            self.assertEqual(missing["id"], f"claude@{module.folder_hash(gone)}")
            self.assertEqual(missing["label"], "claude-arbeit")

    def test_missing_config_dir_is_manual_too(self):
        home = Home(self)
        home.folder(".claude", email="privat@example.com")
        home.manual(config_dir=home.path(".claude-kunde-a"))   # Name wie automatisch, aber nicht vorhanden
        for module in self.each():
            self.assertEqual(summary(module.discover_accounts())[1], ("claude-kunde-a", "manual", "missingFolder"))

    def test_no_default_folder_no_account(self):
        Home(self)
        for module in self.each():
            self.assertEqual(module.discover_accounts(), [])

    def test_default_without_claude_json_is_kept(self):
        home = Home(self)
        home.folder(".claude", claude_json=False)
        for module in self.each():
            self.assertEqual(summary(module.discover_accounts()), [("Standard", "default", "ok")])

    def test_duplicates_count_once(self):
        home = Home(self)
        home.folder(".claude", email="privat@example.com", uuid="u-privat")
        arbeit = home.folder(".claude-arbeit", email="arbeit@example.com", uuid="u-arbeit")
        link = home.path("link-arbeit")
        os.symlink(arbeit, link)
        same_login = home.folder("kopie", email="privat@example.com", uuid="u-privat")
        gone = home.path("weg")
        home.manual(link, arbeit + "/", same_login, gone, gone)
        for module in self.each():
            self.assertEqual([a["label"] for a in module.discover_accounts()], ["privat", "arbeit", "weg"])


class SelectionTest(unittest.TestCase):
    @staticmethod
    def info(*pcts):
        return {"plan": "Max 5×", "limits": [{"title": "Session", "pct": p} for p in pcts], "extra": None}

    def test_tightest_over_all_accounts(self):
        accounts = [{"id": "claude", "info": self.info(20, 40)},
                    {"id": "claude@aaaaaaaa", "info": self.info(10, 91)},
                    {"id": "claude@bbbbbbbb", "info": None},
                    {"id": "claude@cccccccc", "info": self.info(91)}]
        for name, module in MODULES.items():
            with self.subTest(module=name):
                self.assertEqual(module.tightest_id(accounts), "claude@aaaaaaaa")   # Gleichstand: das frühere
                self.assertEqual(module.tightest_id([{"id": "claude", "info": None},
                                                     {"id": "claude@aaaaaaaa", "info": self.info()}]), "claude")
                self.assertIsNone(module.tightest_id([]))
                self.assertIsNone(module.worst_pct(self.info()))
                self.assertEqual(module.worst_pct(self.info(3, 7.5)), 7.5)

    def test_pick_account(self):
        accounts = [{"id": "claude", "info": self.info(20)}, {"id": "claude@aaaaaaaa", "info": self.info(60)}]
        self.assertEqual(gtk.pick_account(accounts, "claude")["id"], "claude")
        self.assertEqual(gtk.pick_account(accounts, None)["id"], "claude@aaaaaaaa")
        self.assertEqual(gtk.pick_account(accounts, "claude@weg")["id"], "claude@aaaaaaaa")
        self.assertIsNone(gtk.pick_account([], None))


class ViewTest(unittest.TestCase):
    """account_view: Zustandspunkt, „!“ und Texte der Seite."""

    def view(self, module, account, info, error, count=2):
        v = module.account_view(account, info, error, count)
        v["error"] = v.pop("error", None) or v.pop("note", None)
        return v

    def test_missing_folder_view(self):
        home = Home(self)
        home.folder(".claude", email="privat@example.com")
        home.manual(home.path("usb/claude-arbeit"))
        for name, module in MODULES.items():
            with self.subTest(module=name):
                missing = module.discover_accounts()[1]
                v = self.view(module, missing, *module.limits_with_cache(missing))
                self.assertTrue(v["problem"])
                self.assertIsNone(v["pct"])
                self.assertEqual(v["title"], "Claude · claude-arbeit")
                self.assertEqual(v["missing"], MISSING_TEXT)
                self.assertEqual(v["folder"], "~/usb/claude-arbeit")   # steht auf eigener Zeile darüber
                self.assertEqual(v["missingHint"], MISSING_HINT)

    def test_problem_flags(self):
        account = {"id": "claude", "folder": None, "dir": "/x/.claude", "label": "privat", "state": "ok"}
        info = SelectionTest.info(85)
        for name, module in MODULES.items():
            with self.subTest(module=name):
                fetch_error = self.view(module, account, None, "HTTP 500")
                self.assertTrue(fetch_error["problem"])
                paused = self.view(module, account, info, "Abfrage pausiert (Rate-Limit) · wieder ab 12:00")
                self.assertFalse(paused["problem"])   # letzter Stand bleibt sichtbar
                self.assertEqual(paused["pct"], 85)
                loading = self.view(module, account, None, None)
                self.assertFalse(loading["problem"])
                self.assertIsNone(loading["missing"])
                self.assertEqual(self.view(module, account, info, None, count=1)["title"], "Claude")

    def test_fetch_error_sentence_once(self):
        """HTTP-Fehler als Satz wie auf macOS; ohne Stand nur im Inhalt, nicht noch einmal in der Fußzeile (GTK)."""
        account = {"id": "claude", "folder": None, "dir": "/x/.claude", "label": "privat", "state": "ok"}
        error = "Server antwortet mit HTTP 503."
        without = gtk.account_view(account, None, error, 2)
        self.assertIsNone(gtk.footer_note("limits", without, None))
        with_info = gtk.account_view(account, SelectionTest.info(40), error, 2)
        self.assertEqual(gtk.footer_note("limits", with_info, None), error)
        self.assertEqual(gtk.footer_note("usage", without, "Verbrauch: OSError"), "Verbrauch: OSError")
        self.assertIsNone(gtk.footer_note("limits", None, None))
        for name, module in MODULES.items():
            with self.subTest(module=name):
                with open(module.__file__) as f:
                    source = f.read()
                self.assertIn('f"Server antwortet mit HTTP {e.code}."', source)
        with open(os.path.join(LINUX, "plasma", "org.tokenstats.claude", "contents", "ui", "FullView.qml")) as f:
            self.assertIn("withValues && view.acc.errorParts", f.read())   # Plasma: Fußzeile nur mit Stand

    def test_catalog_texts(self):
        for name, module in MODULES.items():
            with self.subTest(module=name):
                self.assertEqual(module.MISSING_FOLDER_TEXT, MISSING_TEXT)
                self.assertEqual(module.MISSING_FOLDER_HINT, MISSING_HINT)
        self.assertEqual(gtk.EMPTY_TITLE, EMPTY_TITLE)
        for name, module in MODULES.items():
            with self.subTest(module=name):
                # leerer Zustand direkt als Teile; als Satz gelesen ist es der Katalogtext
                self.assertEqual(sentence(module.EMPTY_PARTS), EMPTY_TEXT)
                self.assertEqual([p["kind"] for p in module.EMPTY_PARTS], ["text", "cmd", "text", "cmd"])
        ui = os.path.join(LINUX, "plasma", "org.tokenstats.claude", "contents", "ui")
        for qml_file in ("FullView.qml", "PartsText.qml"):
            with open(os.path.join(ui, qml_file)) as f:
                qml = f.read()
            self.assertNotIn("Elide", qml.replace("Text.ElideNone", ""), qml_file)
        with open(os.path.join(ui, "FullView.qml")) as f:
            qml = f.read()
        self.assertIn(f'"{EMPTY_TITLE}"', qml)
        self.assertIn("view.info.emptyParts", qml)
        self.assertNotIn("»", qml)   # Befehle kommen als Teile aus dem Backend, nie in »…« im Text


def _luminance(hexcolor):
    channels = [int(hexcolor.lstrip("#")[i:i + 2], 16) / 255 for i in (0, 2, 4)]
    channels = [c / 12.92 if c <= 0.04045 else ((c + 0.055) / 1.055) ** 2.4 for c in channels]
    return 0.2126 * channels[0] + 0.7152 * channels[1] + 0.0722 * channels[2]


def contrast(a, b):
    high, low = sorted((_luminance(a), _luminance(b)), reverse=True)
    return (high + 0.05) / (low + 0.05)


class ContrastTest(unittest.TestCase):
    """Rote Sätze mit mindestens 4,5:1 (WCAG AA): GTK auf festem Grund #1e1e1e, Plasma je Breeze-Thema."""

    def test_gtk_red_text(self):
        self.assertGreaterEqual(contrast(gtk.RED_TEXT, "#1e1e1e"), 4.5)
        self.assertLess(contrast(gtk.hexc(gtk.RED), "#1e1e1e"), 4.5)   # Gegenprobe: das Balkenrot reicht nicht

    def test_plasma_red_text(self):
        with open(os.path.join(LINUX, "plasma", "org.tokenstats.claude", "contents", "ui", "FullView.qml")) as f:
            qml = f.read()
        self.assertIn('darkTheme ? "#f59a8a" : "#952f1a"', qml)
        self.assertGreaterEqual(contrast("#952f1a", "#eff0f1"), 4.5)   # Breeze hell
        self.assertGreaterEqual(contrast("#f59a8a", "#202326"), 4.5)   # Breeze dunkel
        self.assertLess(contrast("#da4453", "#eff0f1"), 4.5)   # Gegenprobe: negativeTextColor von Breeze
        self.assertLess(contrast("#da4453", "#202326"), 4.5)


class NoRequestTest(unittest.TestCase):
    def test_missing_folder_is_not_queried(self):
        home = Home(self)
        gone = home.path("usb/claude-arbeit")
        home.manual(gone)
        for name, module in MODULES.items():
            with self.subTest(module=name):
                account = module.discover_accounts()[0]
                self.assertEqual(module.limits_with_cache(account), (None, None))
                self.assertFalse(os.path.exists(module.LIMITS_CACHE))   # auch kein Versuch vermerkt

    def test_account_without_credentials_needs_no_request(self):
        home = Home(self)
        home.folder(".claude-arbeit", email="arbeit@example.com")
        for name, module in MODULES.items():
            with self.subTest(module=name):
                account = module.discover_accounts()[0]
                info, error = module.limits_with_cache(account)
                self.assertIsNone(info)
                self.assertEqual(error, "Nicht angemeldet: »CLAUDE_CONFIG_DIR=~/.claude-arbeit claude« starten")
                self.assertEqual(module.text_parts(error), [
                    {"kind": "text", "text": "Nicht angemeldet:"},
                    {"kind": "cmd", "text": "CLAUDE_CONFIG_DIR=~/.claude-arbeit claude"},
                    {"kind": "text", "text": "starten"}])


class PartsTest(unittest.TestCase):
    """text_parts: Satzteile und Befehle, damit die Anzeige Befehle nie innerhalb eines Tokens umbricht."""

    def each(self):
        for name, module in MODULES.items():
            with self.subTest(module=name):
                yield module

    def test_split(self):
        for module in self.each():
            self.assertEqual(module.text_parts("Anmeldung abgelaufen: »claude« starten"), [
                {"kind": "text", "text": "Anmeldung abgelaufen:"}, {"kind": "cmd", "text": "claude"},
                {"kind": "text", "text": "starten"}])
            parts = module.text_parts("Nicht angemeldet: »CLAUDE_CONFIG_DIR=~/konten/kunde-a claude auth login« ausführen")
            self.assertEqual(parts[1], {"kind": "cmd", "text": "CLAUDE_CONFIG_DIR=~/konten/kunde-a claude auth login"})

    def test_plain_and_empty(self):
        for module in self.each():
            self.assertEqual(module.text_parts("HTTP 500"), [{"kind": "text", "text": "HTTP 500"}])
            self.assertEqual(module.text_parts("Offline (URLError)"), [{"kind": "text", "text": "Offline (URLError)"}])
            self.assertEqual(module.text_parts(None), [])
            self.assertEqual(module.text_parts(""), [])
            self.assertEqual(module.text_parts("»claude«"), [{"kind": "cmd", "text": "claude"}])
            self.assertEqual(module.text_parts("»  «"), [])

    def test_old_cache_with_backticks(self):
        for module in self.each():
            self.assertEqual(module.text_parts("Nicht angemeldet: `claude` starten")[1], {"kind": "cmd", "text": "claude"})

    def test_prefix_for_status_line(self):
        parts = gtk.text_parts("Anmeldung abgelaufen: »claude« starten")
        self.assertEqual(gtk.prefixed("Stand 12:00  ·  ⚠", parts)[0],
                         {"kind": "text", "text": "Stand 12:00  ·  ⚠ Anmeldung abgelaufen:"})
        self.assertEqual(gtk.prefixed("Stand 12:00  ·  ⚠", [{"kind": "cmd", "text": "claude"}]),
                         [{"kind": "text", "text": "Stand 12:00  ·  ⚠"}, {"kind": "cmd", "text": "claude"}])


class InlineTest(unittest.TestCase):
    """Kurze Befehle im Satz statt allein auf einer Zeile; Breiten des CommandLabel (GTK)."""

    def test_short_command_joins_the_sentence(self):
        parts = gtk.inline_parts(gtk.EMPTY_PARTS)
        self.assertEqual([p["kind"] for p in parts], ["text", "cmd"])
        self.assertEqual(parts[0]["text"], "Melde dich mit claude an. Weitere Ordner:")
        self.assertEqual([s["mono"] for s in parts[0]["segments"]], [False, True, False])
        self.assertEqual(parts[1]["text"], "TOKENSTATS_CLAUDE_DIRS=/pfad/eins:/pfad/zwei")   # lang: eigene Zeilen
        self.assertEqual(gtk.segments_markup(parts[0]["segments"]),
                         'Melde dich mit <span font_family="monospace">claude</span> an. Weitere Ordner:')

    def test_commands_with_spaces_stay_apart(self):
        parts = gtk.inline_parts(gtk.text_parts("Nicht angemeldet: »claude auth login« ausführen"))
        self.assertEqual([p["kind"] for p in parts], ["text", "cmd", "text"])
        self.assertEqual(gtk.inline_parts([{"kind": "cmd", "text": "claude"}]),
                         [{"kind": "text", "text": "claude", "segments": [{"text": "claude", "mono": True}]}])

    def test_backend_matches_gtk(self):
        cases = [gtk.EMPTY_PARTS, gtk.text_parts("Anmeldung abgelaufen: »claude« starten"),
                 gtk.text_parts("Nicht angemeldet: »CLAUDE_CONFIG_DIR=~/.claude-arbeit claude« starten"), []]
        for parts in cases:
            self.assertEqual(backend.inline_parts(parts), gtk.inline_parts(parts))

    @unittest.skipUnless(shutil.which("node"), "node fehlt")
    def test_util_js_rich_text(self):
        with open(os.path.join(LINUX, "plasma", "org.tokenstats.claude", "contents", "code", "util.js")) as f:
            js = f.read().replace(".pragma library", "")
        segments = backend.inline_parts(backend.EMPTY_PARTS)[0]["segments"] + [{"text": "a<b", "mono": False}]
        js += "\nconsole.log(JSON.stringify([hasMono(" + json.dumps(segments) + "), segmentsRich(" + json.dumps(segments) + ")]));\n"
        out = subprocess.run(["node", "-"], input=js, capture_output=True, text=True, check=True).stdout
        self.assertEqual(json.loads(out), [True, 'Melde dich mit <span style="font-family: monospace">claude</span> '
                                                 'an. Weitere Ordner: a&lt;b'])

    def test_markup_is_escaped(self):
        self.assertEqual(gtk.segments_markup([{"text": "a<b & c>", "mono": False}]), "a&lt;b &amp; c&gt;")

    def test_command_label_natural_width_never_below_minimum(self):
        # GTK warnte: „min size 97 and natural size 49“ – »claude« ist kürzer als die 12 Zeichen Mindestbreite
        self.assertEqual(gtk.command_label_widths(8, "claude", 12), (49, 49))
        self.assertEqual(gtk.command_label_widths(8, "CLAUDE_CONFIG_DIR=~/.claude-arbeit claude", 12), (97, 329))
        for command in ("x", "claude", "a b c", "CLAUDE_CONFIG_DIR=~/x claude auth login"):
            low, natural = gtk.command_label_widths(7.5, command, 12)
            self.assertLessEqual(low, natural, command)


class FormatTest(unittest.TestCase):
    """Zahlen deutsch („2,8 M“, „2,09 $“), Wochentage deutsch – in GTK, im Backend und in util.js (Plasma)."""

    def test_python(self):
        for name, module in MODULES.items():
            with self.subTest(module=name):
                self.assertEqual(module.decimal(2.09), "2,09")
                self.assertEqual(module.decimal(1234.5), "1.234,50")
                self.assertEqual(module.decimal(2_800_000 / 1e6, 1), "2,8")
        self.assertEqual((gtk.fmt(2_800_000), gtk.fmt(1_250_000), gtk.fmt(245_000), gtk.fmt(12)),
                         ("2,8 M", "1,2 M", "245 k", "12"))
        self.assertEqual((gtk.money(2.09), gtk.money(1234.5)), ("2,09 $", "1.234,50 $"))

    def test_gtk_weekdays(self):
        from datetime import date, timedelta
        monday = date(2026, 11, 30)
        self.assertEqual([gtk.weekday_short(monday + timedelta(days=i)) for i in range(7)],
                         ["Mo", "Di", "Mi", "Do", "Fr", "Sa", "So"])

    @unittest.skipUnless(shutil.which("node"), "node fehlt")
    def test_util_js(self):
        with open(os.path.join(LINUX, "plasma", "org.tokenstats.claude", "contents", "code", "util.js")) as f:
            js = f.read().replace(".pragma library", "")
        js += """
console.log(JSON.stringify([fmtTokens(2800000), fmtTokens(1250000), fmtTokens(245000), fmtMoney(2.09),
  fmtMoney(1234.5), fmtMoney(0), weekdayShort(new Date(2026, 10, 30, 12)), weekdayShort(new Date(2026, 10, 24, 12)),
  aggregate([{date: "2026-11-30", models: []}], 7).series[0].label]));
"""
        out = subprocess.run(["node", "-"], input=js, capture_output=True, text=True, check=True).stdout
        self.assertEqual(json.loads(out), ["2,8 M", "1,3 M", "245 k", "2,09 $", "1.234,50 $", "0,00 $", "Mo", "Di", "Mo"])

    def test_qml_uses_german_helpers(self):
        with open(os.path.join(LINUX, "plasma", "org.tokenstats.claude", "contents", "ui", "FullView.qml")) as f:
            qml = f.read()
        self.assertNotIn("ddd", qml)
        self.assertIn("U.weekdayShort(d)", qml)
        self.assertIn("QQC2.ScrollBar.horizontal.policy: QQC2.ScrollBar.AlwaysOff", qml)
        self.assertIn("visible: view.acc.limits.length > 0", qml)


class WrapCommandTest(unittest.TestCase):
    """wrap_command: Befehle nie abschneiden, nie breiter als verfügbar; Plasma (util.js) rechnet gleich."""
    KUNDE = "CLAUDE_CONFIG_DIR=~/konten/kunde-a claude"

    def each(self):
        for name, module in MODULES.items():
            with self.subTest(module=name):
                yield module

    def test_fits_on_one_line(self):
        for module in self.each():
            self.assertEqual(module.wrap_command(self.KUNDE, 80), [self.KUNDE])
            self.assertEqual(module.wrap_command("  claude   auth  login ", 80), ["claude auth login"])

    def test_prefers_spaces(self):
        for module in self.each():
            self.assertEqual(module.wrap_command(self.KUNDE, 38), ["CLAUDE_CONFIG_DIR=~/konten/kunde-a", "  claude"])
            self.assertEqual(module.wrap_command("claude auth login", 12), ["claude auth", "  login"])

    def test_breaks_after_slash_and_equals(self):
        for module in self.each():
            # kein Leerzeichen passt: zuerst nach „=“, dann nach „/“, dann nach „- _ . :“; das Zeichen bleibt am Ende
            self.assertEqual(module.wrap_command("CLAUDE_CONFIG_DIR=~/konten/kunde-a", 28),
                             ["CLAUDE_CONFIG_DIR=", "  ~/konten/kunde-a"])
            self.assertEqual(module.wrap_command("CLAUDE_CONFIG_DIR=~/x", 19), ["CLAUDE_CONFIG_DIR=", "  ~/x"])
            self.assertEqual(module.wrap_command("TOKENSTATS_CLAUDE_DIRS=/pfad/eins:/pfad/zwei", 30),
                             ["TOKENSTATS_CLAUDE_DIRS=", "  /pfad/eins:/pfad/zwei"])
            self.assertEqual(module.wrap_command("/pfad/eins:/pfad/zwei", 12), ["/pfad/eins:/", "  pfad/zwei"])
            self.assertEqual(module.wrap_command("abc-defgh", 6), ["abc-", "  defg", "  h"])

    def test_designer_example(self):
        command = "CLAUDE_CONFIG_DIR=~/.claude-alt claude"
        for module in self.each():
            self.assertEqual(module.wrap_command(command, 29), ["CLAUDE_CONFIG_DIR=", "  ~/.claude-alt claude"])
            self.assertEqual(module.wrap_command(command, 20), ["CLAUDE_CONFIG_DIR=", "  ~/.claude-alt", "  claude"])
            for width in range(5, 45):   # nie direkt nach dem Punkt in „~/.claude“
                self.assertFalse(any(line.endswith("/.") for line in module.wrap_command(command, width)), width)

    def test_dot_starting_a_folder_is_no_break(self):
        for module in self.each():
            self.assertEqual(module.wrap_command("~.abcdef", 3), ["~.a", "  b", "  c", "  d", "  e", "  f"])
            self.assertEqual(module.wrap_command(".abcdef", 3), [".ab", "  c", "  d", "  e", "  f"])
            self.assertEqual(module.wrap_command("x.abcdef", 3), ["x.", "  a", "  b", "  c", "  d", "  e", "  f"])

    def test_hard_break_as_last_resort(self):
        for module in self.each():
            self.assertEqual(module.wrap_command("abcdefghijkl", 5), ["abcde", "  fgh", "  ijk", "  l"])

    def test_indent_and_never_too_long(self):
        rng = random.Random(7)
        alphabet = "abcXYZ019 /=_-.:~"
        for module in self.each():
            for _ in range(300):
                command = "".join(rng.choice(alphabet) for _ in range(rng.randint(1, 90)))
                width = rng.randint(1, 40)
                lines = module.wrap_command(command, width)
                self.assertTrue(all(len(line) <= width for line in lines), (command, width, lines))
                if width >= 3:
                    self.assertTrue(all(line.startswith("  ") and line[2] != " " for line in lines[1:]), lines)
                # nichts geht verloren: nur Leerzeichen an Bruchstellen fallen weg
                self.assertEqual("".join(lines).replace(" ", ""), command.replace(" ", ""))

    @unittest.skipUnless(shutil.which("node"), "node fehlt")
    def test_util_js_matches(self):
        rng = random.Random(11)
        cases = [(self.KUNDE, w) for w in range(1, 45)]
        cases += [("CLAUDE_CONFIG_DIR=~/.claude-alt claude", w) for w in range(1, 45)]
        cases += [("".join(rng.choice("ab1 /=_-.:~") for _ in range(rng.randint(1, 60))), rng.randint(1, 30))
                  for _ in range(400)]
        with open(os.path.join(LINUX, "plasma", "org.tokenstats.claude", "contents", "code", "util.js")) as f:
            js = f.read().replace(".pragma library", "")
        js += "\nconst cases = " + json.dumps(cases) + ";\n"
        js += "console.log(JSON.stringify(cases.map(c => wrapCommand(c[0], c[1], 2))));\n"
        out = subprocess.run(["node", "-"], input=js, capture_output=True, text=True, check=True).stdout
        self.assertEqual(json.loads(out), [backend.wrap_command(c, w) for c, w in cases])


class BackendOutputTest(unittest.TestCase):
    def run_main(self):
        out = io.StringIO()
        with contextlib.redirect_stdout(out):
            backend.main()
        return json.loads(out.getvalue())

    def test_output_with_missing_folder(self):
        home = Home(self)
        home.folder(".claude", email="privat@example.com", uuid="u-privat")
        kunde = home.folder("kunde-a", email="kunde-a@example.com", uuid="u-kunde")
        home.manual(kunde, home.path("usb/claude-arbeit"))
        # Stand im Cache, frisch genug: kein Abruf
        os.makedirs(home.cache)
        now = backend.time.time()
        cached = {"accounts": {
            "claude": {"info": SelectionTest.info(30), "attemptedAt": now, "retryAt": 0, "error": None},
            f"claude@{backend.folder_hash(kunde)}": {"info": SelectionTest.info(88), "attemptedAt": now,
                                                     "retryAt": 0, "error": None}}}
        with open(backend.LIMITS_CACHE, "w") as f:
            json.dump(cached, f)
        result = self.run_main()
        self.assertEqual([a["title"] for a in result["accounts"]],
                         ["Claude · privat", "Claude · kunde-a", "Claude · claude-arbeit"])
        self.assertEqual(result["tightest"], f"claude@{backend.folder_hash(kunde)}")
        self.assertEqual(result["usageAccounts"], 2)
        missing = result["accounts"][2]
        self.assertEqual((missing["state"], missing["problem"], missing["pct"], missing["limits"]),
                         ("missingFolder", True, None, []))
        self.assertEqual((missing["missing"], missing["folder"]), (MISSING_TEXT, "~/usb/claude-arbeit"))
        self.assertEqual(result["accounts"][1]["pct"], 88)
        self.assertFalse(result["accounts"][1]["problem"])
        self.assertEqual(result["accounts"][1]["errorParts"], [])
        self.assertEqual(missing["errorParts"], [])   # Ordner fehlt: kein Abruf, also kein Fehlertext

    def test_output_empty(self):
        Home(self)
        result = self.run_main()
        self.assertEqual((result["accounts"], result["tightest"], result["usageAccounts"]), ([], None, 0))
        self.assertEqual(result["emptyParts"], backend.inline_parts(backend.EMPTY_PARTS))
        self.assertEqual(result["emptyParts"][0]["text"], "Melde dich mit claude an. Weitere Ordner:")


if __name__ == "__main__":
    unittest.main()
