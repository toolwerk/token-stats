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
        // Runde 5: Auch die kürzeste Stufe nennt den Weg zur Lösung.
        let notSignedIn = "Keine Anmeldung in diesem Ordner. Im Terminal »CLAUDE_CONFIG_DIR=~/claude-alt claude« starten."
        #expect(CommandSplit.shortVariants(notSignedIn) == [
            notSignedIn,
            "Keine Anmeldung. Im Terminal starten: »CLAUDE_CONFIG_DIR=~/claude-alt claude«",
            "Keine Anmeldung – Befehl in Token Stats.",
        ])
        #expect(CommandSplit.shortVariants("Nicht angemeldet. »codex login« im Terminal ausführen.") == [
            "Nicht angemeldet. »codex login« im Terminal ausführen.",
            "Nicht angemeldet. Im Terminal starten: »codex login«",
            "Nicht angemeldet – Befehl in Token Stats.",
        ])
        let missingFolder = "Ordner nicht gefunden: /Volumes/Daten/kunde-a. Ist das Laufwerk eingehängt, erscheint das Konto von selbst wieder."
        #expect(CommandSplit.shortVariants(missingFolder) == [missingFolder, "Ordner fehlt – Details in Token Stats."])
        #expect(CommandSplit.shortVariants(LimitsAccounts.missingMessage)
            == [LimitsAccounts.missingMessage, "Konto fehlt – Widget bearbeiten."])
        #expect(CommandSplit.shortVariants("Noch kein Stand – Token Stats fragt beim nächsten Takt ab.").last
            == "Noch kein Stand – kommt mit der nächsten Abfrage.")
        #expect(CommandSplit.shortVariants("Anmeldung abgelaufen. »claude« im Terminal einmal starten.").last
            == "Anmeldung abgelaufen – Befehl in Token Stats.")
        #expect(CommandSplit.shortVariants("Server antwortet nicht. Später erneut.").last
            == "Server antwortet nicht – Details in Token Stats.", "unbekannter Typ: erster Satz und Weg")
        for variants in [notSignedIn, missingFolder, LimitsAccounts.missingMessage].map(CommandSplit.shortVariants) {
            #expect(variants.last?.contains("–") == true, "kürzeste Stufe nennt immer den Weg")
        }
    }

    @Test func sentenceEndIgnoresAbbreviations() {
        #expect(CommandSplit.firstSentence("Ordner fehlt, z. B. auf dem Laufwerk. Danach weiter.") == "Ordner fehlt, z. B. auf dem Laufwerk.")
        #expect(CommandSplit.firstSentence("Pause ca. 5 Min. Dann wieder. Weiter.") == "Pause ca. 5 Min. Dann wieder.")
        #expect(CommandSplit.firstSentence("Ein Satz. Zweiter Satz.") == "Ein Satz.")
        #expect(CommandSplit.firstSentence("Nur ein Satz ohne Punkt") == "Nur ein Satz ohne Punkt")
        #expect(CommandSplit.firstSentence("Nicht angemeldet. »codex login« starten.") == "Nicht angemeldet.", "» beginnt einen neuen Teil")
    }

    @Test func separatorDotStartsTheNextLine() {
        // Für die zweizeiligen Teilungen gehört „· “ zum folgenden Teil.
        #expect(WidgetHeader.breakTokens("Claude · Kunde A") == ["Claude ", "· Kunde ", "A"])
    }

    // Runde 6: gemessen statt gezählt. Breiten je Zeichen frei wählbar; hier 1 je Zeichen,
    // breite Großbuchstaben 2.
    private func titleLines(_ text: String, _ available: CGFloat, wide: Set<Character> = []) -> [String] {
        let characters = Array(text)
        let widths = characters.map { wide.contains($0) ? CGFloat(2) : 1 }
        return TitleWrap.lines(characters, widths: widths, available: available).map { String(characters[$0]) }
    }

    @Test func titleDotLeadsWhenThePartFits() {
        #expect(titleLines("Claude · Agentur Nord", 14) == ["Claude", "· Agentur Nord"])
        #expect(titleLines("Claude · Kunde A", 30) == ["Claude · Kunde A"], "passt in eine Zeile")
        // Große Tabelle: nicht „Claude · Agentur“ / „Nord“, sondern am Punkt teilen.
        #expect(titleLines("Claude · Agentur Nord", 17) == ["Claude", "· Agentur Nord"])
        #expect(titleLines("Claude · Kunde Schmidt Beratung", 18) == ["Claude · Kunde", "Schmidt Beratung"],
                "passt „· Konto“ nicht in eine Zeile, normaler Umbruch")
    }

    @Test func titleDotStaysWhenTheWordIsTooWide() {
        // „MÖBELWERKSTATT“: 14 Zeichen, aber breit (28). „· MÖBELWERKSTATT“ (30) passt nicht in
        // 29, das Wort allein schon – der Punkt bleibt am Ende der Vorzeile.
        let caps = Set("MÖBELWERKSTAT")
        #expect(titleLines("Claude · MÖBELWERKSTATT", 29, wide: caps) == ["Claude ·", "MÖBELWERKSTATT"])
        #expect(titleLines("Claude · MÖBELWERKSTATT", 30, wide: caps) == ["Claude", "· MÖBELWERKSTATT"], "passt es, führt der Punkt")
        // Ist das Wort allein zu breit, bricht es als letzter Ausweg zeichenweise.
        #expect(titleLines("Claude · MÖBELWERKSTATT", 20, wide: caps) == ["Claude ·", "MÖBELWERKS", "TATT"])
        // „kundenbetreuung-“ ist schmaler: dort führt der Punkt.
        #expect(titleLines("Claude · kundenbetreuung-niederlassung-sued", 18)
            == ["Claude", "· kundenbetreuung-", "niederlassung-sued"])
    }

    @Test func characterBreakKeepsAtLeastThreeCharacters() {
        // Runde 7/8: kein einzelnes „T“ oder „TT“ als letztes Stück – genaue Erwartungen.
        #expect(titleLines("MÖBELWERKSTATT", 13) == ["MÖBELWERKST", "ATT"], "nicht „MÖBELWERKSTAT“ / „T“")
        #expect(titleLines("MÖBELWERKSTATT", 12) == ["MÖBELWERKST", "ATT"], "nicht „MÖBELWERKSTA“ / „TT“")
        #expect(titleLines("MÖBELWERKSTATT", 11) == ["MÖBELWERKST", "ATT"], "passt schon so")
        #expect(titleLines("MÖBELWERKSTATT", 10) == ["MÖBELWERKS", "TATT"])
        for width in stride(from: CGFloat(4), through: 13, by: 1) {
            let lines = titleLines("MÖBELWERKSTATT", width)
            #expect(lines.count == 1 || (lines.last?.count ?? 0) >= TitleWrap.minimumTail, "Breite \(width)")
        }
    }

    @Test func wholeLineIsMeasuredWithKerning() {
        // Runde 7: Summe der Einzelzeichen ist bei Großbuchstaben zu breit.
        let word = "MÖBELWERKSTATT"
        let whole = TextWidth.measure([(word, .bold)], size: 12)
        let sum = word.map { TextWidth.measure([(String($0), .bold)], size: 12) }.reduce(0, +)
        #expect(whole <= sum)
        #expect(whole > 0)
    }

    @Test func tableTakesStageL5InsteadOfBreakingAWord() {
        // Runde 7, §11: Die Tabelle bricht nie im Wort. „Verwaltungsgesellschaft“ passt in der
        // kleinsten Kachel (308 pt Inhalt) nicht in die normale Kontospalte, aber in die von L5.
        let accounts = DemoAccounts.accounts(.multi, now: now) + [DemoAccounts.longWordAccount(now: now)]
        let rows = LimitsAccounts.rows(DemoAccounts.widgetSnapshot(accounts, now: now))
        #expect(LimitsAccountTable.needsStacked(rows, total: 308))
        let word = WrappedTitle.widestUnbreakable("Claude · Verwaltungsgesellschaft", size: 11, prefix: "Claude · ",
                                                  prefixWeight: .semibold, accountWeight: .regular)
        #expect(word <= LimitsAccountTable.nameWidth(total: 308, stacked: true))
        // Nur kurze Namen (multi): normale Tabelle. „many“ enthält den langen automatischen
        // Namen, der seit Runde 8 wegen mehr als 3 Zeilen zu Recht L5 auslöst.
        let normal = LimitsAccounts.rows(DemoAccounts.widgetSnapshot(DemoAccounts.accounts(.multi, now: now), now: now))
        #expect(!LimitsAccountTable.needsStacked(normal, total: 308), "kurze Namen bleiben in der normalen Tabelle")
    }

    @Test func twentyAccountsInTheSmallestTileTakeL5() {
        // Runde 8, §11: höchstens 3 Zeilen je Kontoname. Bei 20 Konten in der kleinsten großen
        // Kachel (308 pt Inhalt) bräuchte „Claude · kundenbetreuung-niederlassung-sued“ in der
        // normalen Spalte 4 Zeilen – also L5, gemessen mit dem echten Umbruch.
        let rows = LimitsAccounts.rows(DemoAccounts.widgetSnapshot(DemoAccounts.widgetAccounts(count: 20, now: now), now: now))
        let available = LimitsAccountTable.nameWidth(total: 308, stacked: false) - LimitsAccountTable.columnSlack
        let lines = WrappedTitle.lineCount("Claude · kundenbetreuung-niederlassung-sued", size: LimitsAccountTable.nameSize,
                                           prefix: "Claude · ", prefixWeight: .semibold, accountWeight: .regular, available: available)
        #expect(lines > LimitsAccountTable.maxNameLines)
        #expect(LimitsAccountTable.needsStacked(rows, total: 308))
        // In L5 kommt derselbe Name mit höchstens 3 Zeilen aus.
        let stacked = LimitsAccountTable.nameWidth(total: 308, stacked: true) - LimitsAccountTable.columnSlack
        #expect(WrappedTitle.lineCount("Claude · kundenbetreuung-niederlassung-sued", size: LimitsAccountTable.nameSize,
                                       prefix: "Claude · ", prefixWeight: .semibold, accountWeight: .regular, available: stacked)
            <= LimitsAccountTable.maxNameLines)
    }

    @Test func narrowFitCountsAsTooWide() {
        // Runde 8, §5: 2 pt Spielraum. „MÖBELWERKSTATT“ (≈ 103 pt) in der 104-pt-Spalte der
        // kleinsten großen Kachel nimmt L5.
        let accounts = DemoAccounts.accounts(.multi, now: now) + [DemoAccounts.wideNameAccount(now: now)]
        let rows = LimitsAccounts.rows(DemoAccounts.widgetSnapshot(accounts, now: now))
        #expect(LimitsAccountTable.columnSlack == 2)
        #expect(LimitsAccountTable.needsStacked(rows, total: 308))
    }

    @Test func detailLinesStartWithTheSeparator() {
        #expect(WidgetHeader.detailVariant([nil, "Max 20× · +1 Limit"], 1) == ["Max 20×", "· +1 Limit"])
        #expect(WidgetHeader.detailVariant(["knappstes Konto", "Claude · Pro · +2 Limits"], 2)
            == ["knappstes Konto", "Claude", "· Pro", "· +2 Limits"])
        #expect(WidgetHeader.detailTokens("Max 20× · +1 Limit") == ["Max 20×", "· +1 Limit"], "kein Leerzeichen am Ende")
    }

    @Test func titleNeverWiderThanAvailable() {
        let caps = Set("MÖBELWERKSTAT")
        for available in stride(from: CGFloat(6), through: 40, by: 1) {
            for text in ["Claude · MÖBELWERKSTATT", "Claude · Kunde Schmidt Beratung", "Claude · kundenbetreuung-niederlassung-sued"] {
                let characters = Array(text)
                let widths = characters.map { caps.contains($0) ? CGFloat(2) : 1 }
                let lines = TitleWrap.lines(characters, widths: widths, available: available)
                #expect(lines.allSatisfy { $0.map { widths[$0] }.reduce(0, +) <= available || $0.count == 1 },
                        "\(text) bei \(available)")
                #expect(lines.map { String(characters[$0]) }.joined().replacingOccurrences(of: " ", with: "")
                    == text.replacingOccurrences(of: " ", with: ""), "nichts geht verloren")
            }
        }
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
