import Foundation
import Testing
@testable import TokenStatsCore

// Widget „Limits“ mit mehreren Konten (SPEC §6): Auswahl, Migration alter Widgets, Tabelle.
// Nur Demo-Werte.

@Suite struct LimitsAccountsTests {
    let now = Date(timeIntervalSince1970: 1_800_000_000)

    private var multi: WidgetSnapshot { DemoAccounts.widgetSnapshot(DemoAccounts.accounts(.multi, now: now), now: now) }

    // MARK: Migration

    @Test func legacyEnumValuesStillResolve() {
        // Rohwerte des früheren `LimitsProviderOption`; der alte Parameter bleibt erhalten.
        for raw in LimitsAccounts.legacyIDs {
            let shown = LimitsAccounts.selection(account: nil, legacy: raw)
            #expect(shown == (raw == "tightest" ? nil : raw), "\(raw) darf nicht auf „Knappstes Limit“ zurückspringen")
            let choice = LimitsAccounts.choice(for: raw, in: multi)
            #expect(choice.title != raw, "Titel statt roher Kennung")
            #expect(choice.subtitle != "nicht mehr da", "\(raw) ist im Demo-Stand vorhanden")
        }
        #expect(LimitsAccounts.selection(account: nil, legacy: nil) == nil, "neues Widget: knappstes Limit")
        #expect(LimitsAccounts.selection(account: "claude@e5f6a7b8", legacy: "codex") == "claude@e5f6a7b8", "neue Auswahl gewinnt")
        #expect(LimitsAccounts.selection(account: "tightest", legacy: "claude") == nil, "ausdrücklich „Knappstes Limit“")
    }

    @Test func legacyClaudeShowsDefaultAccountNotTightest() {
        // Variante B (Sven, 27.11.2026): „claude“ ist das Standardkonto, auch wenn ein anderes knapper ist.
        #expect(multi.provider("claude@e5f6a7b8")?.snapshot?.tightestWindow?.percent == 1.0)
        let shown = LimitsWidgetView.resolve(multi, provider: LimitsAccounts.selection(account: nil, legacy: "claude"))
        #expect(shown?.id == "claude")
        #expect(shown?.name == "Claude · Privat")
    }

    @Test func tightestOfKindFollowsTheValues() {
        let id = LimitsAccounts.tightestID(kind: "claude")
        #expect(id == "claude@knappstes")
        #expect(LimitsAccounts.tightestKind(id) == "claude")
        #expect(multi.provider(id)?.name == "Claude · Kunde A")
        #expect(multi.provider("codex@knappstes")?.id == "codex", "ein Konto: das eine")
        #expect(multi.provider("ollama@knappstes")?.id == "ollama")
        #expect(multi.provider("gemini@knappstes") == nil)
    }

    @Test func hiddenOrRemovedAccountIsNamedNotRaw() {
        var accounts = DemoAccounts.accounts(.multi, now: now)
        accounts[0].hidden = true // Standardkonto „Privat“ ausgeblendet
        accounts.remove(at: 2) // „Kunde A“ entfernt – Name ist dann nicht mehr bekannt
        var snapshot = DemoAccounts.widgetSnapshot(accounts, now: now)
        #expect(snapshot.provider("claude") == nil, "kein stiller Wechsel auf ein anderes Konto")

        let hidden = LimitsAccounts.choice(for: "claude", in: snapshot)
        #expect(hidden.title == "Claude · Privat")
        #expect(hidden.subtitle == "nicht mehr da")

        let removed = LimitsAccounts.choice(for: "claude@e5f6a7b8", in: snapshot)
        #expect(removed.title == "Claude · Konto")
        #expect(removed.subtitle == "nicht mehr da")
        #expect(!removed.title.contains("@"))

        snapshot.accountNames?["claude@e5f6a7b8"] = "Claude · Kunde A"
        #expect(LimitsAccounts.choice(for: "claude@e5f6a7b8", in: snapshot).title == "Claude · Kunde A")
    }

    // MARK: Liste

    @Test func listIsGroupedPerProvider() {
        let groups = LimitsAccounts.groups(multi)
        #expect(groups.map(\.title) == [nil, "Claude", nil])
        #expect(groups[0].choices.map(\.id) == ["tightest", "antigravity"])
        #expect(groups[1].choices.map(\.id) == ["claude@knappstes", "claude", "claude@a1b2c3d4", "claude@e5f6a7b8"])
        #expect(groups[1].choices[0].title == "Claude – knappstes Konto", "erster Eintrag der Claude-Gruppe")
        #expect(groups[1].choices[1].subtitle == "Standard")
        #expect(groups[2].choices.map(\.title) == ["Codex", "Ollama"])
    }

    @Test func oneAccountPerProviderLooksLikeBefore() {
        let snapshot = DemoAccounts.widgetSnapshot(DemoAccounts.accounts(.one, now: now), now: now)
        let groups = LimitsAccounts.groups(snapshot)
        #expect(groups.count == 1)
        #expect(groups[0].choices.map(\.title) == ["Knappstes Limit", "Antigravity", "Claude", "Codex", "Ollama"])
    }

    @Test func withoutWidgetFileTheFixedProviderList() {
        let groups = LimitsAccounts.groups(nil)
        #expect(groups.flatMap(\.choices).map(\.id) == LimitsAccounts.legacyIDs)
        #expect(LimitsAccounts.choice(for: "claude", in: nil).title == "Claude")
    }

    @Test func searchMatchesTitles() {
        let snapshot = DemoAccounts.widgetSnapshot(DemoAccounts.accounts(.many, now: now), now: now)
        #expect(LimitsAccounts.choices(matching: "kunde", in: snapshot).map(\.title)
            == ["Claude · Kunde A", "Claude · Kunde B", "Claude · Kunde Schmidt Beratung",
                "Claude · kundenbetreuung-niederlassung-sued"])
        #expect(LimitsAccounts.choices(matching: "", in: snapshot).count == 1 + 1 + 9 + 2)
        #expect(!LimitsAccounts.choices(matching: "", in: snapshot).contains { $0.title.contains("Testkonto") }, "ausgeblendet")
    }

    // MARK: Großes Widget

    @Test func tableShowsErrorsFirstThenByTightestLimit() {
        let snapshot = DemoAccounts.widgetSnapshot(DemoAccounts.accounts(.invalid, now: now), now: now)
        let rows = LimitsAccounts.rows(snapshot)
        let failed = rows.prefix { $0.window == nil }.map(\.id)
        #expect(Set(failed) == ["claude@a1b2c3d4", "claude@e5f6a7b8", "claude@c0ffee00"])
        let percents = rows.dropFirst(failed.count).compactMap(\.window?.percent)
        #expect(percents == percents.sorted(by: >))
        #expect(!rows.contains { $0.id == "claude@d00dfeed" }, "doppelte Anmeldung nicht doppelt")
        #expect(rows.first { $0.id == "claude@e5f6a7b8" }?.provider.message?.hasPrefix("Ordner nicht gefunden") == true)
    }

    @Test func overflowLineSummarisesTheRest() {
        let snapshot = DemoAccounts.widgetSnapshot(DemoAccounts.widgetAccounts(count: 20, now: now), now: now)
        let rows = LimitsAccounts.rows(snapshot)
        #expect(rows.count == 20)
        #expect(rows.first?.provider.name == "Claude · Kunde A")
        #expect(LimitsAccounts.overflowText(rows.dropFirst(13)) == "+7 weitere Konten · höchstens 26 %")
        #expect(LimitsAccounts.overflowText(rows.suffix(1)) == "+1 weiteres Konto · höchstens 5 %")
        #expect(LimitsAccounts.countText(snapshot) == "20 Konten")
        let one = DemoAccounts.widgetSnapshot(DemoAccounts.accounts(.one, now: now), now: now)
        #expect(LimitsAccounts.countText(one) == "4 Anbieter")
    }

    @Test func longAutomaticLabelIsNeverShortened() {
        // Punkt 6 der Designer-Prüfung: automatische Bezeichnung mit mehr als 30 Zeichen.
        let label = "kundenbetreuung-niederlassung-sued"
        #expect(label.count == 34)
        let many = DemoAccounts.widgetSnapshot(DemoAccounts.accounts(.many, now: now), now: now)
        #expect(many.provider("claude@2468ace0")?.name == "Claude · \(label)")
        #expect(LimitsAccounts.choice(for: "claude@2468ace0", in: many).title == "Claude · \(label)")
        let twenty = DemoAccounts.widgetSnapshot(DemoAccounts.widgetAccounts(count: 20, now: now), now: now)
        #expect(LimitsAccounts.rows(twenty).contains { $0.provider.name == "Claude · \(label)" }, "Tabellenzeile")
    }

    @Test func commandsAreSplitOutOfSentences() {
        #expect(CommandSplit.parts("Keine Anmeldung in diesem Ordner. Im Terminal »CLAUDE_CONFIG_DIR=~/claude-alt claude« starten.")
            == [.text("Keine Anmeldung in diesem Ordner. Im Terminal"), .command("CLAUDE_CONFIG_DIR=~/claude-alt claude"), .text("starten.")])
        #expect(CommandSplit.parts("Etwa »codex«. Danach weiter.") == [.text("Etwa"), .command("codex"), .text("Danach weiter.")],
                "Punkt hinter dem Befehl entfällt")
        #expect(CommandSplit.parts("Nur Text.") == [.text("Nur Text.")])
        #expect(CommandSplit.parts("»codex login«") == [.command("codex login")])
        #expect(CommandSplit.parts("Offen »ohne Ende") == [.text("Offen »ohne Ende")], "ohne schließendes « kein Befehl")
    }

    @Test func notesHaveShorterVariants() {
        // Runde 4: „keine Anmeldung“ ragte in der kleinsten Kachel in den unteren Innenrand.
        let notSignedIn = "Keine Anmeldung in diesem Ordner. Im Terminal »CLAUDE_CONFIG_DIR=~/claude-alt claude« starten."
        #expect(CommandSplit.shortVariants(notSignedIn) == [
            notSignedIn,
            "Keine Anmeldung. Im Terminal starten: »CLAUDE_CONFIG_DIR=~/claude-alt claude«",
            "Keine Anmeldung.",
        ])
        let missing = "Ordner nicht gefunden: /Volumes/Daten/kunde-a. Ist das Laufwerk eingehängt, erscheint das Konto von selbst wieder."
        #expect(CommandSplit.shortVariants(missing) == [missing, "Ordner nicht gefunden: /Volumes/Daten/kunde-a."])
        #expect(CommandSplit.shortVariants(LimitsAccounts.missingMessage).last == "Konto ausgeblendet oder Ordner fehlt.")
        #expect(CommandSplit.shortVariants("Nicht angemeldet. »codex login« im Terminal ausführen.")[1]
            == "Nicht angemeldet. Im Terminal starten: »codex login«")
        #expect(CommandSplit.shortVariants("Kurz.") == ["Kurz."], "ohne kürzere Fassung nur der Text")
    }

    // MARK: Datei

    @Test func oldWidgetFilesStayReadable() throws {
        let old = try WidgetSnapshot(showMoney: true, providers: [
            .init(id: "claude", name: "Claude", snapshot: nil),
        ], usage: []).jsonData()
        var json = try #require(JSONSerialization.jsonObject(with: old) as? [String: Any])
        json["accountNames"] = nil
        let decoded = try #require(WidgetSnapshot.decode(JSONSerialization.data(withJSONObject: json)))
        #expect(decoded.accountNames == nil)
        #expect(decoded.provider("claude")?.providerKind == "claude")

        let roundTrip = try #require(WidgetSnapshot.decode(multi.jsonData()))
        #expect(roundTrip.accountNames?["claude@e5f6a7b8"] == "Claude · Kunde A")
    }
}
