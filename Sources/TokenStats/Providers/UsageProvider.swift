import CryptoKit
import Foundation
import TokenStatsCore

/// Ein Anbieter = eine Datei, die dieses Protokoll erfüllt (SPEC §7). Jede Instanz steht
/// für ein Konto; ein Anbieter kann mehrere haben (SPEC §6 „Mehrere Konten je Anbieter“).
protocol UsageProvider: Sendable {
    /// Konto-ID: beim Standardkonto die Anbieter-ID (`claude`), sonst `claude@<hash>`.
    var id: String { get }
    /// Anbieter-ID, für alle Konten eines Anbieters gleich.
    var kind: String { get }
    /// Name des Anbieters, ohne Konto.
    var displayName: String { get }
    /// Herkunft des Kontos, für Bezeichnung und Einstellungen.
    var source: AccountSource { get }
    /// Credential-Quelle vorhanden?
    func isInstalled() -> Bool
    func fetch() async throws -> ProviderSnapshot
}

extension UsageProvider {
    var kind: String { id }
    var source: AccountSource { AccountSource() }
    var isDefaultAccount: Bool { id == kind }
}

/// Woher ein Konto kommt – nur Ordner und Kontodaten, keine Zugangsdaten.
struct AccountSource: Sendable, Equatable {
    enum Origin: Int, Sendable, Comparable {
        case standard, detected, manual
        static func < (lhs: Origin, rhs: Origin) -> Bool { lhs.rawValue < rhs.rawValue }

        /// Abzeichen in den Einstellungen.
        var badge: String {
            switch self {
            case .standard: "Standard"
            case .detected: "automatisch gefunden"
            case .manual: "von Hand"
            }
        }
    }

    /// Höchstlänge einer eigenen Bezeichnung (Sven, 27.11.2026): passt in jeder Widget-Größe
    /// in höchstens zwei Titelzeilen. Gilt bei der Eingabe; angezeigt wird nie gekürzt.
    static let maxLabelLength = 24

    /// Konfigurationsordner (`~/.claude-2`); `nil` bei Anbietern mit fester Quelle.
    var folder: URL?
    var origin: Origin = .standard
    /// Kontokennung des Anbieters (`accountUuid`, ChatGPT-`account_id`) – erkennt doppelte Anmeldungen.
    var identity: String?
    var email: String?
    var name: String?

    /// Kurzform für Hinweise: `~/.claude-2`.
    var folderDisplay: String? {
        guard let folder else { return nil }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let path = folder.path
        return path.hasPrefix(home + "/") ? "~" + path.dropFirst(home.count) : path
    }

    /// Woher die automatische Bezeichnung kommt, für den Hinweis unter dem Eingabefeld.
    var automaticLabelSource: String? {
        if let email, let local = email.split(separator: "@").first, !local.isEmpty { return "aus der E-Mail" }
        if let name, !name.isEmpty { return "aus dem Kontonamen" }
        if folder != nil { return "aus dem Ordnernamen" }
        return nil
    }

    /// Automatische Bezeichnung: lokaler Teil der E-Mail, Anzeigename, Ordnername.
    var automaticLabel: String? {
        if let email, let local = email.split(separator: "@").first, !local.isEmpty { return String(local) }
        if let name, !name.isEmpty { return name }
        if let folder {
            let last = folder.lastPathComponent
            return last.hasPrefix(".") ? String(last.dropFirst()) : last
        }
        return nil
    }
}

/// Stabile Kurzkennung eines Ordners: die ersten 8 Hex-Zeichen von SHA-256(Pfad).
/// Claude Code nutzt dieselbe Rechnung für den Schlüsselbund-Dienst bei `CLAUDE_CONFIG_DIR`.
enum FolderHash {
    static func of(_ path: String) -> String {
        SHA256.hash(data: Data(path.utf8)).prefix(4).map { String(format: "%02x", $0) }.joined()
    }
}

enum ProviderError: Error, Equatable {
    case notLoggedIn(hint: String)
    /// Ablaufzeit des Tokens liegt laut Zugangsdaten in der Vergangenheit – ohne Anfrage.
    case tokenExpired(hint: String)
    /// Server hat das Token abgewiesen (HTTP 401/403).
    case unauthorized(hint: String)
    /// Token abgelaufen, aber kein Fehler: Der Anbieter erneuert es bei der nächsten
    /// Nutzung, und bis dahin ändert sich auch das Kontingent nicht (Antigravity).
    case waitingForToken(hint: String)
    case rateLimited(retryAfter: TimeInterval?)
    case http(status: Int)
    case badResponse
    case network(String)

    var message: String {
        switch self {
        case .notLoggedIn(let hint): "Nicht angemeldet. \(hint)"
        case .tokenExpired(let hint), .unauthorized(let hint): "Anmeldung abgelaufen. \(hint)"
        case .waitingForToken(let hint): hint
        case .rateLimited: "Abfragelimit erreicht."
        case .http(let status): "Server antwortet mit HTTP \(status)."
        case .badResponse: "Unerwartete Antwort vom Server."
        case .network(let text): "Keine Verbindung: \(text)"
        }
    }

    /// Fehler aus der lokalen Prüfung der Zugangsdaten: Es ging keine Anfrage raus,
    /// also zählt der Versuch nicht gegen das Abfrageintervall.
    var isLocal: Bool {
        switch self {
        case .notLoggedIn, .tokenExpired, .waitingForToken: true
        default: false
        }
    }
}
