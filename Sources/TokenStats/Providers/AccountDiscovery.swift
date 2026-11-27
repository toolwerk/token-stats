import Foundation

/// Ein erkanntes Konto und ob damit etwas nicht stimmt (SPEC §6 „Mehrere Konten“).
/// Einträge verschwinden nie unbemerkt: Ein fehlender oder doppelter Ordner „von Hand“
/// bleibt in den Einstellungen sichtbar und lässt sich dort entfernen.
struct AccountEntry {
    enum Status: Equatable {
        case ok
        /// Ordner „von Hand“ existiert nicht (Laufwerk nicht eingehängt, gelöscht).
        case missingFolder
        /// Ordner „von Hand“ ohne Kontodatei – dort hat sich die CLI noch nicht angemeldet.
        case notSignedIn
        /// Gleicher Ordner oder gleiche Anmeldung wie das Konto mit dieser ID; nie abgefragt.
        case duplicate(of: String)
    }

    let provider: any UsageProvider
    let status: Status

    var id: String { provider.id }

    var isDuplicate: Bool {
        if case .duplicate = status { return true }
        return false
    }
}

/// Findet die Konten aller Anbieter (SPEC §6 „Mehrere Konten je Anbieter“): das
/// Standardkonto, Ordner wie `~/.claude-2` direkt im Home und von Hand hinzugefügte Ordner.
/// Liest nur Ordnerlisten und Kontodateien, keine Tokens.
struct AccountDiscovery {
    /// Anbieter, deren Konten in eigenen Ordnern liegen können.
    enum FolderKind: String, CaseIterable, Sendable {
        case claude, codex

        var displayName: String {
            switch self {
            case .claude: "Claude"
            case .codex: "Codex"
            }
        }

        /// Standardordner, relativ zum Home.
        var standardFolder: String {
            switch self {
            case .claude: ".claude"
            case .codex: ".codex"
            }
        }

        /// Datei, an der ein Konfigurationsordner als Konto erkennbar ist.
        var marker: String {
            switch self {
            case .claude: ".claude.json"
            case .codex: "auth.json"
            }
        }

        /// Umgebungsvariable, mit der die CLI einen anderen Ordner nimmt.
        var variable: String {
            switch self {
            case .claude: "CLAUDE_CONFIG_DIR"
            case .codex: "CODEX_HOME"
            }
        }

        /// Befehl, mit dem man sich in diesem Ordner anmeldet.
        func signInCommand(folder: String) -> String {
            switch self {
            case .claude: "CLAUDE_CONFIG_DIR=\(folder) claude"
            case .codex: "CODEX_HOME=\(folder) codex login"
            }
        }
    }

    var home: URL = FileManager.default.homeDirectoryForCurrentUser
    /// Von Hand hinzugefügte Ordner je Anbieter.
    var manualFolders: [String: [String]] = [:]

    /// Alle Einträge, auch fehlende und doppelte – für die Einstellungen.
    func entries() -> [AccountEntry] {
        var result: [AccountEntry] = []
        for kind in FolderKind.allCases {
            result += entries(kind)
        }
        result.append(AccountEntry(provider: AntigravityProvider(), status: .ok))
        result.append(AccountEntry(provider: OllamaProvider(), status: .ok))
        return result
    }

    /// Konten, die Popover und Abfrage kennen: alles außer doppelten Anmeldungen.
    func providers() -> [any UsageProvider] {
        entries().filter { !$0.isDuplicate }.map(\.provider)
    }

    func accounts(_ kind: FolderKind) -> [any UsageProvider] {
        entries(kind).filter { !$0.isDuplicate }.map(\.provider)
    }

    /// Standard vor automatisch vor von Hand. Doppelte Ordner (gleicher echter Pfad) und
    /// doppelte Anmeldungen (gleiche `accountUuid` bzw. `account_id`) bleiben als Eintrag
    /// stehen, zählen aber nicht: Sonst gingen zwei Abfragen gegen dasselbe Rate-Limit.
    func entries(_ kind: FolderKind) -> [AccountEntry] {
        let standard = make(kind, folder: nil, origin: .standard)
        var folderOwners: [String: String] = [
            home.appending(path: kind.standardFolder).resolvingSymlinksInPath().standardizedFileURL.path: standard.id,
        ]
        var identityOwners: [String: String] = [:]
        if let identity = standard.source.identity { identityOwners[identity] = standard.id }

        var result = [AccountEntry(provider: standard, status: .ok)]
        var seenManual: Set<String> = []
        let manual = (manualFolders[kind.rawValue] ?? []).compactMap { path -> (URL, AccountSource.Origin)? in
            let url = URL(filePath: path).standardizedFileURL
            return seenManual.insert(url.path).inserted ? (url, .manual) : nil
        }
        for (folder, origin) in detectedFolders(kind) + manual {
            let provider = make(kind, folder: folder.standardizedFileURL, origin: origin)
            let real = folder.resolvingSymlinksInPath().standardizedFileURL.path
            if let owner = folderOwners[real] {
                result.append(AccountEntry(provider: provider, status: .duplicate(of: owner)))
                continue
            }
            folderOwners[real] = provider.id
            if let identity = provider.source.identity {
                if let owner = identityOwners[identity] {
                    result.append(AccountEntry(provider: provider, status: .duplicate(of: owner)))
                    continue
                }
                identityOwners[identity] = provider.id
            }
            result.append(AccountEntry(provider: provider, status: status(kind, folder: folder, origin: origin)))
        }
        return result
    }

    /// Zustand eines Ordners; nur Ordner „von Hand“ können fehlen oder leer sein –
    /// automatisch gefundene gibt es per Definition nur mit Kontodatei.
    private func status(_ kind: FolderKind, folder: URL, origin: AccountSource.Origin) -> AccountEntry.Status {
        guard origin == .manual else { return .ok }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: folder.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            return .missingFolder
        }
        return FileManager.default.fileExists(atPath: folder.appending(path: kind.marker).path) ? .ok : .notSignedIn
    }

    /// `~/.claude-*` bzw. `~/.codex-*` (auch mit `_`), sofern die Kontodatei darin liegt.
    func detectedFolders(_ kind: FolderKind) -> [(URL, AccountSource.Origin)] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: home.path)) ?? []
        return names
            .filter { $0.hasPrefix(kind.standardFolder + "-") || $0.hasPrefix(kind.standardFolder + "_") }
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
            .map { home.appending(path: $0) }
            .filter { folder in
                var isDirectory: ObjCBool = false
                return FileManager.default.fileExists(atPath: folder.path, isDirectory: &isDirectory) && isDirectory.boolValue
                    && FileManager.default.fileExists(atPath: folder.appending(path: kind.marker).path)
            }
            .map { ($0, .detected) }
    }

    private func make(_ kind: FolderKind, folder: URL?, origin: AccountSource.Origin) -> any UsageProvider {
        switch kind {
        case .claude: ClaudeProvider(configDirectory: folder, origin: origin)
        case .codex: CodexProvider(home: folder, origin: origin)
        }
    }
}
