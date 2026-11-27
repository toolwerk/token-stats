import Foundation

/// Auswahl im Widget „Limits“ (SPEC §6 „Mehrere Konten je Anbieter“, Widgets).
///
/// Gespeichert wird nur die Kennung. Sie muss über Updates hinweg auflösen:
/// - `tightest`: knappstes Limit über alle Konten (Standard).
/// - `claude`, `codex`, `antigravity`, `ollama`: das **Standardkonto** des Anbieters. Das
///   sind zugleich die Rohwerte des früheren Enums `LimitsProviderOption`; bestehende Widgets
///   zeigen nach dem Update also dasselbe Konto wie vorher (Sven, 27.11.2026, Variante B).
/// - `claude@knappstes`: das knappste Konto eines Anbieters; wechselt von selbst.
/// - `claude@<hash>`: ein weiteres Konto.
///
/// Liegt in TokenStatsCore, damit die Auflösung ohne WidgetKit testbar ist.
public enum LimitsAccounts {
    public static let tightestID = "tightest"
    static let tightestSuffix = "@knappstes"

    /// Rohwerte des früheren Anbieter-Enums – müssen weiter auflösen.
    public static let legacyIDs = ["tightest", "antigravity", "claude", "codex", "ollama"]

    /// Anbieter in der Reihenfolge der Tabs, für die Liste ohne Widget-Stand.
    static let knownKinds: [(id: String, name: String)] = [
        ("antigravity", "Antigravity"), ("claude", "Claude"), ("codex", "Codex"), ("ollama", "Ollama"),
    ]

    /// Satz im Widget, wenn das gewählte Konto nicht im Stand steht.
    public static let missingMessage = "Konto ausgeblendet oder Ordner fehlt. Widget bearbeiten und ein anderes Konto wählen."

    /// Was das Widget zeigt, aus den beiden Parametern des Widgets „Limits“: `account` ist die
    /// neue Kontoauswahl, `legacy` der Rohwert des früheren Enum-Parameters `provider`. Der
    /// alte Parameter bleibt mit unverändertem Typ im Intent (ausgeblendet), damit WidgetKit
    /// gespeicherte Widgets ohne Typumwandlung weiter liest; solange `account` nie gesetzt
    /// wurde, gilt er. Ergebnis `nil` = knappstes Limit über alle Konten.
    public static func selection(account: String?, legacy: String?) -> String? {
        let id = account ?? legacy ?? tightestID
        return id == tightestID ? nil : id
    }

    /// Kennung für „<Anbieter> – knappstes Konto“.
    public static func tightestID(kind: String) -> String { kind + tightestSuffix }

    /// Anbieter einer Kennung `claude@knappstes`, sonst `nil`.
    public static func tightestKind(_ id: String) -> String? {
        id.hasSuffix(tightestSuffix) ? String(id.dropLast(tightestSuffix.count)) : nil
    }

    /// Anbieter einer beliebigen Konto-Kennung (`claude@7c21be90` → `claude`).
    public static func kind(of id: String) -> String {
        String(id.split(separator: "@", maxSplits: 1).first ?? Substring(id))
    }

    public static func kindName(_ kind: String, in snapshot: WidgetSnapshot? = nil) -> String {
        snapshot?.providerName(kind: kind)
            ?? knownKinds.first { $0.id == kind }?.name
            ?? kind.prefix(1).uppercased() + kind.dropFirst()
    }

    // MARK: Liste

    public struct Choice: Equatable, Sendable, Identifiable {
        public var id: String
        public var title: String
        /// „alle Konten“, „Standard“, „wechselt von selbst“, „nicht mehr da“.
        public var subtitle: String?

        public init(id: String, title: String, subtitle: String? = nil) {
            self.id = id
            self.title = title
            self.subtitle = subtitle
        }
    }

    /// Abschnitt der Liste; `title == nil` für Anbieter mit nur einem Konto.
    public struct Group: Equatable, Sendable {
        public var title: String?
        public var choices: [Choice]
    }

    public static let tightestChoice = Choice(id: tightestID, title: "Knappstes Limit", subtitle: "alle Konten")

    /// „Knappstes Limit“, dann die Anbieter in Tab-Reihenfolge. Ein Anbieter mit mehreren
    /// Konten bekommt einen eigenen Abschnitt: zuerst „Claude – knappstes Konto“, dann die
    /// Konten, das Standardkonto mit „Standard“ markiert. Ohne Widget-Stand (ad hoc signierter
    /// Build, App nie gestartet) die feste Anbieterliste wie vor den Konten.
    public static func groups(_ snapshot: WidgetSnapshot?) -> [Group] {
        guard let snapshot, !snapshot.providers.isEmpty else {
            return [Group(title: nil, choices: [tightestChoice] + knownKinds.map { Choice(id: $0.id, title: $0.name) })]
        }
        var groups: [Group] = [Group(title: nil, choices: [tightestChoice])]
        var kinds: [String] = []
        for provider in snapshot.providers where !kinds.contains(provider.providerKind) {
            kinds.append(provider.providerKind)
        }
        for kind in kinds {
            let accounts = snapshot.providers.filter { $0.providerKind == kind }
            if accounts.count == 1 {
                let choice = Choice(id: accounts[0].id, title: accounts[0].name)
                if groups[groups.count - 1].title == nil {
                    groups[groups.count - 1].choices.append(choice)
                } else {
                    groups.append(Group(title: nil, choices: [choice]))
                }
            } else {
                let name = kindName(kind, in: snapshot)
                var choices = [Choice(id: tightestID(kind: kind), title: "\(name) – knappstes Konto", subtitle: "wechselt von selbst")]
                choices += accounts.map { Choice(id: $0.id, title: $0.name, subtitle: $0.id == kind ? "Standard" : nil) }
                groups.append(Group(title: name, choices: choices))
            }
        }
        return groups
    }

    /// Eintrag für eine gespeicherte Kennung – auch für alte Enum-Werte und für Konten, die
    /// nicht mehr im Stand stehen. Nie die rohe Kennung als Titel.
    public static func choice(for id: String, in snapshot: WidgetSnapshot?) -> Choice {
        if let found = groups(snapshot).flatMap(\.choices).first(where: { $0.id == id }) { return found }
        if let kind = tightestKind(id) {
            // Anbieter hat gerade nur noch ein Konto – die Auswahl gilt weiter.
            return Choice(id: id, title: "\(kindName(kind, in: snapshot)) – knappstes Konto", subtitle: "wechselt von selbst")
        }
        let kind = kind(of: id)
        let title = snapshot?.accountNames?[id] ?? (id == kind ? kindName(kind, in: snapshot) : "\(kindName(kind, in: snapshot)) · Konto")
        return Choice(id: id, title: title, subtitle: "nicht mehr da")
    }

    /// Suche im Systemdialog „Widget bearbeiten“: Titel enthält den Text.
    public static func choices(matching text: String, in snapshot: WidgetSnapshot?) -> [Choice] {
        let needle = text.trimmingCharacters(in: .whitespaces)
        let all = groups(snapshot).flatMap(\.choices)
        guard !needle.isEmpty else { return all }
        return all.filter { $0.title.localizedStandardContains(needle) }
    }

    // MARK: Großes Widget

    /// Eine Zeile der Tabelle „Konto | Knappstes Limit“.
    public struct Row: Identifiable, Sendable {
        public var provider: WidgetSnapshot.Provider
        /// Knappstes Limit; `nil` bei Konten ohne Stand (Fehler).
        public var window: LimitWindow?
        public var id: String { provider.id }
    }

    /// Alle Konten des Stands: Konten ohne Stand (Fehler) zuerst, dann nach knappstem Limit
    /// absteigend. So steht oben, was Aufmerksamkeit braucht, und die Sammelzeile enthält
    /// nie ein knapperes Konto als die gezeigten.
    public static func rows(_ snapshot: WidgetSnapshot) -> [Row] {
        let rows = snapshot.providers.map { Row(provider: $0, window: $0.snapshot?.tightestWindow) }
        let failed = rows.filter { $0.window == nil }
        let ok = rows.filter { $0.window != nil }.enumerated().sorted { a, b in
            let pa = a.element.window?.percent ?? 0, pb = b.element.window?.percent ?? 0
            return pa != pb ? pa > pb : a.offset < b.offset
        }.map(\.element)
        return failed + ok
    }

    /// „+7 weitere Konten · höchstens 26 %“ für die Zeilen, die nicht mehr passen.
    public static func overflowText(_ hidden: some Collection<Row>) -> String {
        let count = hidden.count == 1 ? "+1 weiteres Konto" : "+\(hidden.count) weitere Konten"
        guard let highest = hidden.compactMap(\.window?.percent).max() else { return count }
        return "\(count) · höchstens \(Format.percent(highest))"
    }

    /// Kopfdetail des großen Widgets: „4 Anbieter“ bei einem Konto je Anbieter, sonst „8 Konten“.
    public static func countText(_ snapshot: WidgetSnapshot) -> String {
        let kinds = Set(snapshot.providers.map(\.providerKind))
        let count = snapshot.providers.count
        if kinds.count == count { return count == 1 ? "1 Anbieter" : "\(count) Anbieter" }
        return "\(count) Konten"
    }
}
