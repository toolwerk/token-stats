import Foundation
import Testing
import TokenStatsCore
@testable import TokenStats

// Mehrere Konten je Anbieter (SPEC §6): Kennungen, Erkennung, Bezeichnung, Widget-Auswahl.

@Suite struct AccountTests {
    /// Leeres Home mit Konfigurationsordnern; Kontodaten wie Claude Code und Codex sie ablegen.
    private func makeHome() throws -> URL {
        let home = FileManager.default.temporaryDirectory.appending(path: "accounts-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        return home
    }

    private func claudeFolder(_ home: URL, _ name: String, uuid: String, email: String) throws -> URL {
        let folder = home.appending(path: name)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let json = #"{"oauthAccount":{"accountUuid":"\#(uuid)","emailAddress":"\#(email)","displayName":"Frank"}}"#
        try Data(json.utf8).write(to: folder.appending(path: ".claude.json"))
        return folder
    }

    @Test func keychainServiceFollowsClaudeCode() {
        // Claude Code: "Claude Code-credentials-" + SHA-256(CLAUDE_CONFIG_DIR) in Hex, erste 8 Zeichen.
        #expect(FolderHash.of("/Users/test/.claude-work") == "03abf0ee")
        let provider = ClaudeProvider(configDirectory: URL(filePath: "/Users/test/.claude-work"))
        #expect(provider.keychainServices == ["Claude Code-credentials-03abf0ee", "Claude Code-credentials-8bd6f0f5"])
        #expect(provider.id == "claude@03abf0ee")
        #expect(ClaudeProvider().keychainServices == ["Claude Code-credentials"])
        #expect(ClaudeProvider().id == "claude", "Standardkonto behält die Anbieter-ID")
        #expect(CodexProvider().id == "codex")
    }

    @Test func readsAccountData() throws {
        let json = #"{"oauthAccount":{"accountUuid":"u-1","emailAddress":"frank@example.com","displayName":""}}"#
        let account = try #require(ClaudeProvider.parseAccount(Data(json.utf8)))
        #expect(account == .init(uuid: "u-1", email: "frank@example.com", name: nil))
        #expect(ClaudeProvider.parseAccount(Data("{}".utf8)) == nil)
    }

    @Test func detectsFoldersInHome() throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        _ = try claudeFolder(home, ".claude-2", uuid: "u-2", email: "second@example.com")
        _ = try claudeFolder(home, ".claude_work", uuid: "u-3", email: "work@example.com")
        // Ohne Kontodatei kein Konto, und ähnliche Namen zählen nicht.
        try FileManager.default.createDirectory(at: home.appending(path: ".claude-empty"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: home.appending(path: ".claudeX"), withIntermediateDirectories: true)

        let found = AccountDiscovery(home: home).accounts(.claude)
        #expect(found.count == 3)
        #expect(found[0].isDefaultAccount)
        #expect(Set(found.dropFirst().compactMap(\.source.email)) == ["second@example.com", "work@example.com"])
        #expect(found.dropFirst().allSatisfy { $0.source.origin == .detected })
    }

    @Test func skipsDuplicateLoginsAndKeepsManualFolders() throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        _ = try claudeFolder(home, ".claude-2", uuid: "u-2", email: "second@example.com")
        let copy = try claudeFolder(home, "elsewhere/claude-copy", uuid: "u-2", email: "second@example.com")
        let manual = try claudeFolder(home, "elsewhere/claude-firma", uuid: "u-9", email: "firma@example.com")

        let discovery = AccountDiscovery(home: home, manualFolders: ["claude": [copy.path, manual.path, manual.path]])
        let found = discovery.accounts(.claude).dropFirst()
        #expect(found.map(\.source.email) == ["second@example.com", "firma@example.com"], "dieselbe Anmeldung nur einmal")
        #expect(found.last?.source.origin == .manual)
    }

    @Test func automaticLabel() {
        #expect(AccountSource(email: "frank@example.com", name: "Frank").automaticLabel == "frank")
        #expect(AccountSource(name: "Frank").automaticLabel == "Frank")
        #expect(AccountSource(folder: URL(filePath: "/Users/test/.claude-2")).automaticLabel == "claude-2")
        #expect(AccountSource().automaticLabel == nil)
    }

    @Test func logRootsAreReadOnce() {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let roots = UsageLedger.unique([home.appending(path: ".claude/projects"), home.appending(path: ".claude/projects/")])
        #expect(roots.count == 1)
    }

    @Test func widgetResolvesKindToTightestAccount() {
        let now = Date.now
        func snapshot(_ percent: Double) -> ProviderSnapshot {
            ProviderSnapshot(windows: [LimitWindow(id: "week", name: "Woche", percent: percent)], fetchedAt: now)
        }
        let widget = WidgetSnapshot(showMoney: true, providers: [
            .init(id: "claude", name: "Claude · frank", snapshot: snapshot(0.3), kind: "claude", kindName: "Claude"),
            .init(id: "claude@03abf0ee", name: "Claude · work", snapshot: snapshot(0.7), kind: "claude", kindName: "Claude"),
            .init(id: "codex", name: "Codex", snapshot: snapshot(0.5)),
        ], usage: [])
        #expect(widget.provider("claude")?.id == "claude", "genaue ID gewinnt")
        #expect(widget.provider("claude@03abf0ee")?.name == "Claude · work")
        #expect(widget.provider("codex")?.providerKind == "codex", "alte Dateien ohne kind")
        #expect(widget.providerName(kind: "claude") == "Claude")
        #expect(widget.tightest?.provider.id == "claude@03abf0ee")

        #expect(widget.provider("claude@knappstes")?.id == "claude@03abf0ee", "eigener Eintrag „knappstes Konto“")

        // Variante B (Sven, 27.11.2026): „claude“ ist das Standardkonto. Fehlt es, kein stiller Wechsel.
        let onlySecond = WidgetSnapshot(showMoney: true, providers: [widget.providers[1]], usage: [])
        #expect(onlySecond.provider("claude") == nil)
        #expect(onlySecond.provider("claude@knappstes")?.id == "claude@03abf0ee")
    }

    @MainActor @Test func tabsSortDefaultFirstAndTitleOnlyWithSeveralAccounts() {
        let settings = AppSettings()
        let previousLabels = settings.accountLabels
        let previousHidden = settings.hiddenAccounts
        defer {
            settings.accountLabels = previousLabels
            settings.hiddenAccounts = previousHidden
        }
        settings.hiddenAccounts = []
        let second = ClaudeProvider(configDirectory: FileManager.default.homeDirectoryForCurrentUser)
        settings.accountLabels = [second.id: "zweites"]
        let store = UsageStore(providers: [second, ClaudeProvider()], settings: settings)
        let claude = store.sortedProviders.filter { $0.kind == "claude" }
        #expect(claude.first?.isDefaultAccount == true)
        #expect(store.title(for: second) == "Claude · zweites")

        settings.hiddenAccounts = [second.id]
        #expect(store.title(for: ClaudeProvider()) == "Claude", "ein sichtbares Konto: keine Bezeichnung")
    }

    // MARK: Fehlerzustände (Designer-Entwurf 27.11.2026, Review-Punkte 6–8)

    @Test func missingManualFolderStaysListedAndRemovable() throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let gone = home.appending(path: "Volumes/Daten/kunde-a")
        let entries = AccountDiscovery(home: home, manualFolders: ["claude": [gone.path]]).entries(.claude)
        let entry = try #require(entries.first { $0.provider.source.origin == .manual })
        #expect(entry.status == .missingFolder)
        #expect(!entry.provider.isInstalled())
    }

    @Test func duplicateFoldersAndLoginsAreMarkedNotDropped() throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let detected = try claudeFolder(home, ".claude-2", uuid: "u-2", email: "arbeit@example.com")
        let copy = try claudeFolder(home, "elsewhere/claude-kopie", uuid: "u-2", email: "arbeit@example.com")

        let entries = AccountDiscovery(home: home, manualFolders: ["claude": [copy.path, detected.path]]).entries(.claude)
        let first = try #require(entries.first { $0.provider.source.origin == .detected })
        let duplicates = entries.filter(\.isDuplicate)
        #expect(duplicates.count == 2, "gleiche Anmeldung und gleicher Ordner")
        #expect(duplicates.allSatisfy { $0.status == .duplicate(of: first.id) })
        #expect(duplicates.allSatisfy { $0.provider.source.origin == .manual }, "beide lassen sich entfernen")
        #expect(AccountDiscovery(home: home, manualFolders: ["claude": [copy.path]]).accounts(.claude).count == 2,
                "abgefragt wird nur der erste")
    }

    @Test func manualFolderWithoutLoginIsNotSignedIn() throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let empty = home.appending(path: "codex-leer")
        try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)
        let entries = AccountDiscovery(home: home, manualFolders: ["codex": [empty.path]]).entries(.codex)
        let entry = try #require(entries.first { $0.provider.source.origin == .manual })
        #expect(entry.status == .notSignedIn)
        #expect(!entry.provider.isInstalled(), "Codex ohne auth.json wird nicht abgefragt")
    }

    @MainActor @Test func storeShowsProblemAccountsButPollsOnlyInstalled() throws {
        let settings = AppSettings()
        let previousHidden = settings.hiddenAccounts
        defer { settings.hiddenAccounts = previousHidden }
        settings.hiddenAccounts = []
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let gone = CodexProvider(home: home.appending(path: "fehlt"), origin: .manual)
        let empty = home.appending(path: "codex-leer")
        try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)
        let unsigned = CodexProvider(home: empty, origin: .manual)
        let store = UsageStore(entries: [
            AccountEntry(provider: gone, status: .missingFolder),
            AccountEntry(provider: unsigned, status: .notSignedIn),
            AccountEntry(provider: CodexProvider(home: empty.appending(path: "x"), origin: .manual), status: .duplicate(of: unsigned.id)),
        ], settings: settings)
        #expect(Set(store.visibleProviders.map(\.id)) == [gone.id, unsigned.id], "Fehlerkonten bleiben sichtbar, Doppelte nicht")
        #expect(store.installedProviders.isEmpty, "nichts davon wird abgefragt")
        #expect(store.problem(for: gone)?.hasPrefix("Ordner nicht gefunden: ") == true)
        #expect(store.problem(for: unsigned)?.contains("CODEX_HOME=") == true)
        #expect(store.hasProblem(gone))
    }

    @MainActor @Test func labelIsLimitedTo24Characters() {
        let settings = AppSettings()
        let previous = settings.accountLabels
        defer { settings.accountLabels = previous }
        let store = UsageStore(providers: [], settings: settings)
        store.setLabel("claude@test0001", "  Hausverwaltung Lindenhof GmbH  ")
        #expect(settings.accountLabels["claude@test0001"] == "Hausverwaltung Lindenhof")
        #expect(settings.accountLabels["claude@test0001"]?.count == AccountSource.maxLabelLength)
        store.setLabel("claude@test0001", " ")
        #expect(settings.accountLabels["claude@test0001"] == nil, "leer = automatische Bezeichnung")
    }

    @Test func automaticLabelNamesItsSource() {
        #expect(AccountSource(email: "privat@example.com").automaticLabelSource == "aus der E-Mail")
        #expect(AccountSource(name: "Privat").automaticLabelSource == "aus dem Kontonamen")
        #expect(AccountSource(folder: URL(filePath: "/tmp/.claude-2")).automaticLabelSource == "aus dem Ordnernamen")
    }

    #if DEBUG
    @MainActor @Test func demoAccountsNeverTouchRealAccounts() {
        let settings = AppSettings()
        let store = UsageStore(providers: [], settings: settings)
        let demo = DemoAccountProvider.scenario(.invalid, now: .now)
        let before = (settings.accountLabels, settings.hiddenAccounts)
        store.showDemo(demo.snapshots, entries: demo.entries, errors: demo.errors, hidden: demo.hidden, labels: demo.labels)
        #expect(store.sortedProviders.allSatisfy { $0 is DemoAccountProvider })
        #expect(store.sortedProviders.contains { $0.id == "claude@e5f6a7b8" }, "Ordner fehlt, bleibt sichtbar")
        #expect(!store.sortedProviders.contains { $0.id == "claude@d00dfeed" }, "doppelte Anmeldung")
        store.setLabel("claude", "Umbenannt")
        store.setHidden("codex", true)
        #expect(store.provider(id: "claude").flatMap(store.label(for:)) == "Umbenannt")
        #expect(settings.accountLabels == before.0 && settings.hiddenAccounts == before.1, "Demo schreibt nichts in die Einstellungen")
    }
    #endif

    // MARK: Designer-Prüfung PR #5

    @Test func longAutomaticLabelIsNotShortened() {
        let source = AccountSource(email: DemoAccounts.longEmail)
        #expect(source.automaticLabel == "kundenbetreuung-niederlassung-sued")
        #expect(source.automaticLabel?.count == 34, "länger als 24: automatische Bezeichnungen werden nie gekürzt")
    }

    @Test func knownAccountNamesAreBounded() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let day: TimeInterval = 24 * 3600
        var stored: [String: KnownAccountNames.Entry] = [
            "claude@alt": .init(name: "Claude · Alt", lastSeen: now.addingTimeInterval(-200 * day)),
            "claude@weg": .init(name: "Claude · Kunde A", lastSeen: now.addingTimeInterval(-10 * day)),
        ]
        for index in 0..<60 {
            stored[String(format: "claude@%08x", index)] = .init(name: "Claude · Test \(index)",
                                                                  lastSeen: now.addingTimeInterval(-Double(index + 20) * day))
        }
        let merged = KnownAccountNames.merge(stored: stored, current: ["claude": "Claude · Privat"], now: now)
        #expect(merged["claude"]?.name == "Claude · Privat", "aktuelle Konten immer")
        #expect(merged["claude@weg"]?.name == "Claude · Kunde A", "kürzlich verschwunden: Name bleibt")
        #expect(merged["claude@alt"] == nil, "nach 180 Tagen vergessen")
        #expect(merged.count == 1 + KnownAccountNames.maxVanished, "höchstens 50 verschwundene")
        #expect(merged[String(format: "claude@%08x", 59)] == nil, "die am längsten nicht gesehenen fallen zuerst")
    }
}
