import Foundation
import SwiftUI
import Testing
@testable import TokenStatsCore

// Regeln hinter den Widget-Layouts (SPEC §7 „Widgets“, Entwurf „Widgets einheitlich“) – nur Demo-Werte.

private let now = Date(timeIntervalSince1970: 1_800_000_000)

private func window(_ id: String, _ percent: Double) -> LimitWindow {
    LimitWindow(id: id, name: id.capitalized, percent: percent)
}

private func provider(_ id: String, _ name: String, _ percents: [Double]?, message: String? = nil) -> WidgetSnapshot.Provider {
    let snapshot = percents.map { values in
        ProviderSnapshot(windows: values.enumerated().map { window("w\($0.offset)", $0.element) }, fetchedAt: now)
    }
    return WidgetSnapshot.Provider(id: id, name: name, snapshot: snapshot, message: message)
}

@Suite("Limit-Auswahl")
struct LimitPickTests {
    @Test("Klein zeigt die zwei knappsten Limits, absteigend – bei Claude Woche und Opus")
    func smallShowsTightest() {
        let claude = DemoData.widgetSnapshot(now: now).provider("claude")!.snapshot!.windows
        let pick = LimitPick.tightest(claude, count: LimitPick.small)
        #expect(pick.shown.map(\.name) == ["Woche", "Opus"])
        #expect(pick.hidden == 1)
    }

    @Test("Passen alle, bleibt alles in der Reihenfolge der App")
    func allFit() {
        let windows = [window("session", 0.42), window("week", 0.82), window("opus", 0.64)]
        let pick = LimitPick.tightest(windows, count: LimitPick.medium)
        #expect(pick.shown.map(\.id) == ["session", "week", "opus"])
        #expect(pick.hidden == 0)
    }

    @Test("Passt nur ein Teil, absteigend nach Prozent statt in App-Reihenfolge")
    func partialIsDescending() {
        let windows = [window("session", 0.30), window("week", 0.64), window("opus", 0.82)]
        let pick = LimitPick.tightest(windows, count: 2)
        #expect(pick.shown.map(\.id) == ["opus", "week"])
        #expect(pick.hidden == 1)
    }

    @Test("Gleichstand: das weiter vorn stehende gewinnt")
    func tie() {
        let windows = [window("a", 0.5), window("b", 0.5), window("c", 0.5)]
        #expect(LimitPick.tightest(windows, count: 2).shown.map(\.id) == ["a", "b"])
    }

    @Test("Absteigend für die Tabelle X4: knappstes, dann zweites")
    func descending() {
        let windows = [window("session", 0.42), window("week", 0.82), window("opus", 0.64)]
        #expect(LimitPick.descending(windows, count: 2).map(\.id) == ["week", "opus"])
        #expect(LimitPick.descending([], count: 2).isEmpty)
    }
}

@Suite("Tabelle und Sammelzeilen")
struct LimitsTableTests {
    @Test("Fehlerkonten zuerst, dann nach knappstem Limit absteigend, Gleichstand in App-Reihenfolge")
    func order() {
        let providers = [
            provider("a", "Claude · A", [0.30, 0.40]),
            provider("b", "Claude · B", nil, message: "Anmeldung abgelaufen."),
            provider("c", "Codex", [0.90]),
            provider("d", "Claude · D", [0.40]),
        ]
        #expect(LimitsTable.ordered(providers).map(\.id) == ["b", "c", "a", "d"])
    }

    @Test("Zeilenzahlen der Stufe L4: n−1 … 4, unter fünf Konten keine")
    func rowCounts() {
        #expect(LimitsTable.rowCounts(total: 20) == Array((4...19).reversed()))
        #expect(LimitsTable.rowCounts(total: 5) == [4])
        #expect(LimitsTable.rowCounts(total: 4).isEmpty)
    }

    @Test("„+7 weitere Konten · höchstens 26 %“ – Höchstwert des Rests")
    func moreAccounts() {
        let rest = (0..<7).map { provider("p\($0)", "Claude · P\($0)", [0.10 + Double($0) * 0.02]) }
        #expect(WidgetText.moreAccounts(rest, accounts: true) == "+7 weitere Konten · höchstens 22 %")
        let one = [provider("x", "Claude · X", [0.26])]
        #expect(WidgetText.moreAccounts(one, accounts: true) == "+1 weiteres Konto · höchstens 26 %")
        #expect(WidgetText.moreAccounts(one, accounts: false) == "+1 weiterer Anbieter · höchstens 26 %")
        let failing = [provider("y", "Claude · Y", nil)]
        #expect(WidgetText.moreAccounts(failing, accounts: true) == "+1 weiteres Konto · 1 mit Fehler")
        let mixed = [provider("y", "Claude · Y", nil), provider("z", "Claude · Z", nil), provider("w", "Claude · W", [0.4])]
        #expect(WidgetText.moreAccounts(mixed, accounts: true) == "+3 weitere Konten · höchstens 40 % · 2 mit Fehler")
    }

    @Test("Kopf: „4 Anbieter“ ohne Kontoteil, „8 Konten“ mit")
    func providerCount() {
        #expect(WidgetText.providerCount(DemoData.widgetSnapshot(now: now).providers) == "4 Anbieter")
        #expect(WidgetText.providerCount(DemoData.accountsSnapshot(now: now, count: 8).providers) == "8 Konten")
    }

    @Test("Ausgeblendete Limits und Modelle")
    func hidden() {
        #expect(WidgetText.hiddenLimits(1) == "+1 Limit")
        #expect(WidgetText.hiddenLimits(2) == "+2 Limits")
        #expect(WidgetText.hiddenLimitsInApp(1) == "+1 Limit in der App")
        #expect(WidgetText.moreModels(3) == "+3 weitere Modelle")
        #expect(WidgetText.moreModels(1) == "+1 weiteres Modell")
    }

    @Test("Modellzeilen: groß 6 → 3, extragroß 12 → 4")
    func modelRows() {
        #expect(ModelRows.counts(total: 9) == [6, 5, 4, 3])
        #expect(ModelRows.counts(total: 4) == [4, 3])
        #expect(ModelRows.counts(total: 2) == [2])
        #expect(ModelRows.counts(total: 16, maximum: ModelRows.extraLargeMaximum, minimum: ModelRows.extraLargeMinimum)
                == Array((4...12).reversed()))
        #expect(ModelRows.counts(total: 3, maximum: 12, minimum: 4) == [3])
    }
}

@Suite("Tabelle ohne Limit-Spalte (L5, X5-kurz)")
struct NarrowTableTests {
    @Test("Limitname steht als zweite Zeile und fällt nie weg, auch nicht bei Pause")
    func limitLine() {
        let week = window("week", 0.58)
        #expect(WidgetText.limitLine(week, paused: false) == "Week")
        #expect(WidgetText.limitLine(week, paused: true) == "Week · pausiert")
    }

    /// Rendert die großen Limits in schmalen Kacheln, die L5 bzw. X5-kurz erzwingen – mit
    /// Fehlerkonto, pausierter Abfrage und 24-Zeichen-Namen. Prüft, dass jede Stufenleiter
    /// ohne Laufzeitfehler aufgeht (eindeutige Kennungen in `ViewThatFits`).
    @Test("Schmale Kacheln mit Fehler und Pause rendern")
    @MainActor
    func narrowRender() {
        var snapshot = DemoData.accountsSnapshot(now: now, count: 12)
        snapshot.providers += DemoData.failureSnapshot(now: now).providers.filter { $0.isFailing || $0.isRateLimited }
        snapshot.providers[1].name = "Claude · Hausverwaltung Lindenhof"
        for (size, width, height) in [(WidgetSize.large, 240.0, 300.0), (.extraLarge, 480.0, 300.0), (.large, 308.0, 308.0)] {
            let view = LimitsWidgetView(snapshot: snapshot, provider: nil, size: size, now: now)
                .frame(width: width, height: height)
            #expect(ImageRenderer(content: view).cgImage != nil)
        }
    }
}

@Suite("Spalten im extragroßen Widget")
struct ColumnSplitTests {
    @Test("Abschnitte ausgeglichen verteilt, Reihenfolge bleibt")
    func balanced() {
        // 4 Anbieter: Antigravity, Claude (hoch), Codex, Ollama (niedrig) → zwei links.
        #expect(ColumnSplit.balanced([70, 128, 70, 43], spacing: 12) == 2)
        // Fehler-Stand: Claude hoch, Fehlerkonto, Codex → eins links.
        #expect(ColumnSplit.balanced([128, 44, 70], spacing: 12) == 1)
        #expect(ColumnSplit.balanced([50], spacing: 12) == 1)
        #expect(ColumnSplit.balanced([], spacing: 12) == 0)
    }

    @Test("Tabellen spaltenweise: links ⌈k/2⌉")
    func halves() {
        #expect(ColumnSplit.halves(20) == 10)
        #expect(ColumnSplit.halves(9) == 5)
        #expect(ColumnSplit.halves(1) == 1)
    }
}

@Suite("Kontonamen")
struct AccountNameTests {
    @Test("Höchstens 24 Zeichen, bei der Eingabe – Leerraum zusammengefasst")
    func sanitized() {
        #expect(AccountName.maxLength == 24)
        #expect(AccountName.sanitized("  Hausverwaltung   Lindenhof ") == "Hausverwaltung Lindenhof")
        #expect(AccountName.sanitized("Hausverwaltung Lindenhof Nord").count == 24)
        #expect(!AccountName.sanitized("Hausverwaltung Lindenhof Nord").hasSuffix("…"))
        #expect(AccountName.isValid("Kunde A"))
        #expect(!AccountName.isValid("Hausverwaltung Lindenhof Nord"))
        #expect(!AccountName.isValid(""))
    }

    @Test("Hinweis bei langen Einwort-Namen")
    func readabilityHint() {
        #expect(AccountName.needsReadabilityHint("Verwaltungsgesellschaft"))
        #expect(!AccountName.needsReadabilityHint("Hausverwaltung Lindenhof"))
        #expect(!AccountName.needsReadabilityHint("Verwaltungs-Gesellschaft"))
    }

    @Test("Titel „Claude · Privat“ in Anbieter und Konto zerlegt")
    func title() {
        let title = WidgetTitle("Claude · Kunde Schmidt Beratung")
        #expect(title.provider == "Claude")
        #expect(title.account == "Kunde Schmidt Beratung")
        #expect(title.full == "Claude · Kunde Schmidt Beratung")
        #expect(WidgetTitle("Codex").account == nil)
    }
}

@Suite("Widget-Auswahl")
struct WidgetResolveTests {
    @Test("Gewählter Anbieter zeigt genau dieses Konto (Standardkonto behält die ID), sonst das knappste")
    func resolve() {
        let snapshot = DemoData.accountsSnapshot(now: now, count: 8)
        #expect(LimitsWidgetView.resolve(snapshot, provider: "claude")?.name == "Claude · Privat")
        #expect(LimitsWidgetView.resolve(snapshot, provider: nil)?.name == "Claude · Kunde A")
        #expect(LimitsWidgetView.resolve(snapshot, provider: "unbekannt") == nil)
    }

    @Test("Gewählter Anbieter ohne Stand: Anzeigename statt Kennung")
    func displayName() {
        var empty = DemoData.widgetSnapshot(now: now)
        empty.providers = []
        #expect(ProviderName.display("claude", in: empty) == "Claude")
        #expect(ProviderName.display("antigravity") == "Antigravity")
        #expect(ProviderName.display("neu") == "Neu")
        // Mit Stand zählt der Name aus dem Stand (mit Konten: „Claude · Privat“).
        let accounts = DemoData.accountsSnapshot(now: now, count: 8)
        #expect(ProviderName.display("claude", in: accounts) == "Claude · Privat")
        #expect(DemoData.providerNames.map(\.name) == ["Antigravity", "Claude", "Codex", "Ollama"])
    }

    @Test("Farbschwellen kommen aus Severity: ab 80 % warn, erst ab 100 % crit; Demo hat ein Konto auf 100 %")
    func severity() {
        #expect(Severity(percent: 0.79) == .ok)
        #expect(Severity(percent: 0.93) == .warn)
        #expect(Severity(percent: 1.0) == .crit)
        let kundeA = DemoData.accountsSnapshot(now: now, count: 8).provider("claude-kunde-a")!
        #expect(kundeA.snapshot?.tightestWindow?.percent == 1.0)
        #expect(Format.percent(1.0) == "100 %")
    }

    @Test("Demo-Stände: 8 und 20 Konten, Fehler und pausiert")
    func demo() {
        #expect(DemoData.accountsSnapshot(now: now, count: 8).providers.count == 8)
        #expect(DemoData.accountsSnapshot(now: now, count: 20).providers.count == 20)
        let failure = DemoData.failureSnapshot(now: now)
        #expect(failure.providers.contains { $0.isFailing && $0.message != nil })
        #expect(failure.providers.contains { $0.isRateLimited && $0.snapshot != nil })
    }
}
