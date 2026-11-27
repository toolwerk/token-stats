import Foundation

/// Demo-Konten für mehrere Konten je Anbieter (SPEC §6): `TOKENSTATS_DEMO_ACCOUNTS` in
/// Debug-Builds, Tests und Bilder. Alles erfunden – Bezeichnungen wie im Designer-Entwurf,
/// Adressen unter `example.com`, keine echten Limits, Ordner oder Kontonamen.
public enum DemoAccounts {
    /// Zustände des Entwurfs: 1 Konto je Anbieter, 3 × Claude + Codex, 8 × Claude, keins,
    /// fehlerhafte Ordner.
    public enum Scenario: String, CaseIterable, Sendable {
        case one, multi, many, empty, invalid

        /// Wert der Umgebungsvariable; `1` heißt `multi`.
        public init?(environment value: String?) {
            guard let value, !value.isEmpty, value != "0" else { return nil }
            self = Scenario(rawValue: value.lowercased()) ?? .multi
        }
    }

    public enum Origin: String, Sendable { case standard, detected, manual }

    /// Was mit einem Konto nicht stimmt – wie in der Erkennung der App.
    public enum Problem: Sendable, Equatable {
        case missingFolder
        case notSignedIn
        /// Gleiche Anmeldung wie das Konto mit dieser ID.
        case duplicate(of: String)
    }

    public struct Account: Sendable, Identifiable {
        public var id: String
        public var kind: String
        public var kindName: String
        public var label: String?
        public var email: String?
        /// Ordner wie angezeigt (`~/.claude-arbeit`); `nil` bei Anbietern mit fester Quelle.
        public var folder: String?
        public var origin: Origin
        public var problem: Problem?
        public var hidden: Bool
        public var snapshot: ProviderSnapshot?
        /// Fehlertext der Abfrage, z. B. „Nicht angemeldet“.
        public var error: String?
    }

    // MARK: Zustände

    public static func accounts(_ scenario: Scenario, now: Date) -> [Account] {
        let demo = DemoData.snapshots(now: now)
        let codex = account("codex", "Codex", id: "codex", label: "Privat", email: "codex@example.com", folder: "~/.codex",
                            origin: .standard, snapshot: demo["codex"])
        let others = [
            account("antigravity", "Antigravity", id: "antigravity", origin: .standard, snapshot: demo["antigravity"]),
            account("ollama", "Ollama", id: "ollama", origin: .standard, snapshot: demo["ollama"]),
        ]
        let privat = claude(id: "claude", "Privat", "~/.claude", .standard, session: 0.42, week: 0.82, now: now, plan: "Max 20×")
        let arbeit = claude(id: "claude@a1b2c3d4", "Arbeit", "~/.claude-arbeit", .detected, session: 0.24, week: 0.51, now: now)
        let kundeA = claude(id: "claude@e5f6a7b8", "Kunde A", "/Volumes/Daten/kunde-a", .manual, session: 0.67, week: 1.0, now: now, plan: "Pro")
        // Ohne eigene Bezeichnung: automatisch aus der E-Mail, 34 Zeichen, ein Wort mit
        // Bindestrichen – wird nirgends gekürzt (Designer-Prüfung PR #5, Punkt 6).
        var lang = claude(id: "claude@2468ace0", "Kundenbetreuung", "~/.claude-kundenbetreuung", .detected,
                          session: 0.15, week: 0.47, now: now)
        lang.label = nil
        lang.email = DemoAccounts.longEmail

        switch scenario {
        case .one:
            return [privat, codex] + others
        case .multi:
            return [privat, arbeit, kundeA, codex] + others
        case .many:
            var testkonto = claude(id: "claude@0f1e2d3c", "Testkonto", "~/.claude_test", .detected, session: 0.05, week: 0.12, now: now)
            testkonto.hidden = true
            return [
                privat, arbeit, kundeA,
                claude(id: "claude@9a8b7c6d", "Kunde B", "/Volumes/Daten/kunde-b", .manual, session: 0.12, week: 0.34, now: now),
                claude(id: "claude@11223344", "Kunde Schmidt Beratung", "~/Projekte/kunden/schmidt-beratung/claude-konfiguration",
                       .manual, session: 0.08, week: 0.61, now: now, plan: "Max 5×"),
                claude(id: "claude@55667788", "Agentur Nord", "~/.claude-agentur-nord", .detected, session: 0.31, week: 0.72, now: now),
                testkonto,
                claude(id: "claude@99aabbcc", "Schulung 2027", "~/.claude-schulung", .detected, session: 0.18, week: 0.44, now: now),
                lang,
                codex,
            ] + others
        case .empty:
            return []
        case .invalid:
            var arbeitSignedOut = arbeit
            arbeitSignedOut.snapshot = nil
            arbeitSignedOut.error = "Nicht angemeldet. »CLAUDE_CONFIG_DIR=~/.claude-arbeit claude auth login« im Terminal ausführen."
            var missing = kundeA
            missing.snapshot = nil
            missing.problem = .missingFolder
            var alt = account("claude", "Claude", id: "claude@c0ffee00", label: nil, email: nil, folder: "~/claude-alt", origin: .manual)
            alt.problem = .notSignedIn
            var copy = account("claude", "Claude", id: "claude@d00dfeed", label: nil, email: "privat@example.com",
                               folder: "~/.claude-kopie", origin: .detected)
            copy.problem = .duplicate(of: "claude")
            return [privat, arbeitSignedOut, missing, alt, copy, codex] + others
        }
    }

    /// Viele Claude-Konten für das große Widget (Entwurf: 8 und 20 Konten), dazu Codex.
    public static func widgetAccounts(count: Int, now: Date) -> [Account] {
        let names: [(String, Double, Double)] = [
            ("Kunde A", 0.67, 1.0), ("Privat", 0.42, 0.82), ("Agentur Nord", 0.31, 0.72), ("Kunde Schmidt Beratung", 0.08, 0.61),
            ("Labor", 0.2, 0.58), ("Arbeit", 0.24, 0.51), ("Kunde D", 0.1, 0.47), ("Schulung 2027", 0.18, 0.44),
            ("Support", 0.05, 0.39), ("Kunde B", 0.12, 0.34), ("Kunde F", 0.33, 0.21), ("Kunde C", 0.04, 0.28),
            ("Kunde E", 0.03, 0.26), ("Kunde G", 0.02, 0.22), ("Kunde H", 0.11, 0.19), ("Kunde I", 0.01, 0.15),
            ("Kunde J", 0.0, 0.12), ("Kunde K", 0.02, 0.09), ("Kunde L", 0.0, 0.05),
        ]
        var accounts = names.prefix(max(count - 1, 0)).enumerated().map { index, entry in
            var account = claude(id: index == 1 ? "claude" : String(format: "claude@%08x", 0x1000 + index), entry.0, nil,
                                 index == 1 ? .standard : .detected, session: entry.1, week: entry.2, now: now)
            if entry.0 == "Kunde D" {
                // Automatische Bezeichnung mit 34 Zeichen statt einer eigenen (Punkt 6).
                account.label = nil
                account.email = longEmail
            }
            return account
        }
        if count > 0 {
            let demo = DemoData.snapshots(now: now)
            accounts.append(account("codex", "Codex", id: "codex", origin: .standard, snapshot: demo["codex"]))
        }
        return accounts
    }

    /// Widget-Stand wie ihn die App aus diesen Konten schreibt: nur sichtbare Konten, Titel
    /// „Claude · Privat“ bei mehreren Konten eines Anbieters, Fehler als Hinweis.
    public static func widgetSnapshot(_ accounts: [Account], now: Date) -> WidgetSnapshot {
        // Reihenfolge wie die Tabs: Anbieter alphabetisch, Standardkonto zuerst, dann nach Bezeichnung.
        let visible = accounts.filter { !$0.hidden && !$0.isDuplicate }.sorted { a, b in
            if a.kindName != b.kindName { return a.kindName.localizedStandardCompare(b.kindName) == .orderedAscending }
            if (a.origin == .standard) != (b.origin == .standard) { return a.origin == .standard }
            return (a.displayLabel ?? "").localizedStandardCompare(b.displayLabel ?? "") == .orderedAscending
        }
        let providers = visible.map { account in
            WidgetSnapshot.Provider(
                id: account.id, name: title(account, among: visible), snapshot: account.snapshot,
                message: account.problemText ?? account.error, kind: account.kind, kindName: account.kindName
            )
        }
        var names: [String: String] = [:]
        // Auch ausgeblendete Konten heißen „Claude · Privat“, sobald der Anbieter mehrere kennt.
        let known = accounts.filter { !$0.isDuplicate }
        for account in known {
            let several = known.filter { $0.kind == account.kind }.count > 1
            names[account.id] = several ? account.displayLabel.map { "\(account.kindName) · \($0)" } ?? account.kindName : account.kindName
        }
        return WidgetSnapshot(writtenAt: now.addingTimeInterval(-60), showMoney: true, providers: providers, usage: [],
                              accountNames: names)
    }

    /// „Claude“ bei einem Konto, „Claude · Privat“ bei mehreren.
    public static func title(_ account: Account, among accounts: [Account]) -> String {
        let several = accounts.filter { $0.kind == account.kind && !$0.hidden && !$0.isDuplicate }.count > 1
        guard several, let label = account.displayLabel else { return account.kindName }
        return "\(account.kindName) · \(label)"
    }

    /// Konto mit breitem Einwort-Namen in Großbuchstaben (Designer-Prüfung PR #5, Runde 6):
    /// 14 Zeichen, aber breiter als „kundenbetreuung-“ – prüft den gemessenen Umbruch.
    public static func wideNameAccount(now: Date) -> Account {
        claude(id: "claude@0b5e1a7e", "MÖBELWERKSTATT", "~/.claude-moebel", .detected, session: 0.22, week: 0.58, now: now, plan: "Pro")
    }

    /// Langes Einwort (23 Zeichen, unter der 24-Zeichen-Grenze) – zwingt die Tabelle des großen
    /// Widgets in Stufe L5 statt eines Bruchs im Wort (Designer-Prüfung PR #5, Runde 7).
    public static func longWordAccount(now: Date) -> Account {
        claude(id: "claude@7e1a2b3c", "Verwaltungsgesellschaft", "~/.claude-verwaltung", .detected, session: 0.31, week: 0.66, now: now, plan: "Max 5×")
    }

    /// Adresse, deren lokaler Teil die automatische Bezeichnung mit 34 Zeichen ergibt.
    public static let longEmail = "kundenbetreuung-niederlassung-sued@example.com"

    // MARK: Bausteine

    private static func account(_ kind: String, _ kindName: String, id: String, label: String? = nil, email: String? = nil,
                                folder: String? = nil, origin: Origin, snapshot: ProviderSnapshot? = nil) -> Account {
        Account(id: id, kind: kind, kindName: kindName, label: label, email: email, folder: folder, origin: origin,
                problem: nil, hidden: false, snapshot: snapshot, error: nil)
    }

    private static func claude(id: String, _ label: String, _ folder: String?, _ origin: Origin,
                               session: Double, week: Double, now: Date, plan: String = "Max 20×") -> Account {
        let hour: TimeInterval = 3600
        let snapshot = ProviderSnapshot(
            account: AccountInfo(name: label, plan: plan),
            windows: [
                LimitWindow(id: "session", name: "Session", scopeNote: "5 h", percent: session,
                            resetsAt: now.addingTimeInterval(2.2 * hour), windowLength: 5 * hour),
                LimitWindow(id: "week", name: "Woche", scopeNote: "7 d, alle Modelle", percent: week,
                            resetsAt: now.addingTimeInterval(2.6 * 24 * hour), windowLength: 7 * 24 * hour),
            ],
            fetchedAt: now.addingTimeInterval(-60)
        )
        let mail = label.lowercased().replacingOccurrences(of: " ", with: "-") + "@example.com"
        return account("claude", "Claude", id: id, label: label, email: mail, folder: folder, origin: origin, snapshot: snapshot)
    }
}

extension DemoAccounts.Account {
    public var isDuplicate: Bool {
        if case .duplicate = problem { return true }
        return false
    }

    /// Eigene Bezeichnung, sonst lokaler Teil der E-Mail, sonst Ordnername ohne Punkt – wie
    /// die automatische Bezeichnung der App.
    public var displayLabel: String? {
        if let label { return label }
        if let local = email?.split(separator: "@").first, !local.isEmpty { return String(local) }
        guard let folder else { return nil }
        let last = folder.split(separator: "/").last.map(String.init) ?? folder
        return last.hasPrefix(".") ? String(last.dropFirst()) : last
    }

    /// Satz für die Seite des Kontos, wie in der App.
    public var problemText: String? {
        switch problem {
        case .missingFolder:
            "Ordner nicht gefunden: \(folder ?? ""). Ist das Laufwerk eingehängt, erscheint das Konto von selbst wieder."
        case .notSignedIn:
            "Keine Anmeldung in diesem Ordner. Im Terminal »CLAUDE_CONFIG_DIR=\(folder ?? "") claude« starten."
        case .duplicate, nil:
            nil
        }
    }
}
