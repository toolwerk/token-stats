import Foundation

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
    }

    var home: URL = FileManager.default.homeDirectoryForCurrentUser
    /// Von Hand hinzugefügte Ordner je Anbieter.
    var manualFolders: [String: [String]] = [:]

    /// Alle Konten, Standard vor automatisch vor von Hand, doppelte Anmeldungen nur einmal.
    func providers() -> [any UsageProvider] {
        var result: [any UsageProvider] = []
        for kind in FolderKind.allCases {
            result += accounts(kind)
        }
        result.append(AntigravityProvider())
        result.append(OllamaProvider())
        return result
    }

    func accounts(_ kind: FolderKind) -> [any UsageProvider] {
        let standard = home.appending(path: kind.standardFolder).resolvingSymlinksInPath().standardizedFileURL
        var seenFolders: Set<String> = [standard.path]
        var folders: [(URL, AccountSource.Origin)] = []
        for folder in detectedFolders(kind) + (manualFolders[kind.rawValue] ?? []).map { (URL(filePath: $0), AccountSource.Origin.manual) } {
            let real = folder.0.resolvingSymlinksInPath().standardizedFileURL.path
            guard seenFolders.insert(real).inserted else { continue }
            folders.append((folder.0.standardizedFileURL, folder.1))
        }

        var providers: [any UsageProvider] = [make(kind, folder: nil, origin: .standard)]
        providers += folders.map { make(kind, folder: $0.0, origin: $0.1) }

        // Zwei Ordner mit derselben Anmeldung: nur der erste zählt, sonst doppelte Abfragen.
        var identities: Set<String> = []
        return providers.filter { provider in
            guard let identity = provider.source.identity else { return true }
            return identities.insert(identity).inserted
        }
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
