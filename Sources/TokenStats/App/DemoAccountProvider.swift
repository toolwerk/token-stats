#if DEBUG
import Foundation
import TokenStatsCore

/// Konto aus `DemoAccounts` (TokenStatsCore) für `TOKENSTATS_DEMO_ACCOUNTS`: Einstellungen,
/// Popover und `make screenshots` zeigen damit nur erfundene Konten, nie die echten.
/// Fragt nichts ab und liest keine Dateien.
struct DemoAccountProvider: UsageProvider {
    let id: String
    let kind: String
    let displayName: String
    let source: AccountSource
    private let installed: Bool

    init(_ account: DemoAccounts.Account) {
        id = account.id
        kind = account.kind
        displayName = account.kindName
        let home = FileManager.default.homeDirectoryForCurrentUser
        let folder = account.folder.map { path in
            path.hasPrefix("~/") ? home.appending(path: String(path.dropFirst(2))) : URL(filePath: path)
        }
        source = AccountSource(
            folder: account.origin == .standard ? nil : folder,
            origin: AccountSource.Origin(account.origin),
            email: account.email
        )
        installed = account.problem != .missingFolder && account.problem != .notSignedIn
    }

    func isInstalled() -> Bool { installed }

    func fetch() async throws -> ProviderSnapshot {
        throw ProviderError.notLoggedIn(hint: "Demo-Konto")
    }

    /// Einträge, Stände, Fehler, ausgeblendete Konten und Bezeichnungen eines Demo-Zustands.
    static func scenario(_ scenario: DemoAccounts.Scenario, now: Date) -> (
        entries: [AccountEntry], snapshots: [String: ProviderSnapshot], errors: [String: String],
        hidden: Set<String>, labels: [String: String]
    ) {
        let accounts = DemoAccounts.accounts(scenario, now: now)
        let entries = accounts.map { account in
            let status: AccountEntry.Status = switch account.problem {
            case .missingFolder: .missingFolder
            case .notSignedIn: .notSignedIn
            case .duplicate(let owner): .duplicate(of: owner)
            case nil: .ok
            }
            return AccountEntry(provider: DemoAccountProvider(account), status: status)
        }
        var snapshots: [String: ProviderSnapshot] = [:]
        var errors: [String: String] = [:]
        var labels: [String: String] = [:]
        for account in accounts {
            snapshots[account.id] = account.snapshot
            errors[account.id] = account.error
            labels[account.id] = account.label
        }
        let hidden = Set(accounts.filter(\.hidden).map(\.id))
        return (entries, snapshots, errors, hidden, labels)
    }
}

extension AccountSource.Origin {
    init(_ origin: DemoAccounts.Origin) {
        switch origin {
        case .standard: self = .standard
        case .detected: self = .detected
        case .manual: self = .manual
        }
    }
}
#endif
