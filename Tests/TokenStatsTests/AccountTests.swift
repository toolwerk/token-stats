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

        let onlySecond = WidgetSnapshot(showMoney: true, providers: [widget.providers[1]], usage: [])
        #expect(onlySecond.provider("claude")?.id == "claude@03abf0ee", "Anbieter-ID → knappstes Konto")
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
}
