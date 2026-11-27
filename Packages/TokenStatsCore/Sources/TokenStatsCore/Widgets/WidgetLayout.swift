import Foundation

// Reine Regeln hinter den Widget-Layouts (SPEC §7 „Widgets“): welche Limits ein Widget zeigt,
// in welcher Reihenfolge die Konten im großen Widget stehen und was die Sammelzeilen sagen.
// Die Views in WidgetViews.swift wählen nur noch die passende Stufe.

/// Kontobezeichnungen haben höchstens 24 Zeichen (Entscheidung vom 27.11.2026). Dann braucht
/// ein Name in jeder Widget-Größe höchstens zwei Titelzeilen, und keiner muss gekürzt werden.
/// Die Grenze gilt bei der Eingabe (Einstellungen der Konten, `maxLength` im Feld – kommt mit
/// PR #2); die Widgets selbst kürzen nie, sie brechen am Wortende um.
public enum AccountName {
    public static let maxLength = 24
    /// Ein Wort ab dieser Länge passt im kleinen Widget nicht in eine Titelzeile und bricht dort
    /// in der letzten Stufe zeichenweise (z. B. „Verwaltungsgesellschaft“).
    public static let longWord = 15

    /// Für das Eingabefeld: Leerraum zusammengefasst, außen getrimmt, höchstens `maxLength`
    /// Zeichen. Längeres nimmt das Feld nicht an – ohne „…“, es wird nichts angezeigt, was der
    /// Nutzer nicht so eingegeben hat.
    public static func sanitized(_ raw: String) -> String {
        let collapsed = raw.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return String(collapsed.prefix(maxLength)).trimmingCharacters(in: .whitespaces)
    }

    public static func isValid(_ name: String) -> Bool {
        name == sanitized(name) && !name.isEmpty
    }

    /// Hinweis fürs Eingabefeld: „Mit Leerzeichen oder Bindestrich lesbarer“ – bei einem Wort,
    /// das im kleinen Widget zeichenweise brechen müsste.
    public static func needsReadabilityHint(_ name: String) -> Bool {
        name.split(whereSeparator: { $0.isWhitespace || $0 == "-" }).contains { $0.count >= longWord }
    }
}

/// Titel „Claude · Privat“: Anbieter und Kontoteil. Heute haben die Anbieter keinen Kontoteil;
/// mit mehreren Konten (PR #2) trägt der Name „Anbieter · Konto“.
public struct WidgetTitle: Equatable, Sendable {
    public static let separator = " · "

    public var provider: String
    public var account: String?

    public init(provider: String, account: String?) {
        self.provider = provider
        self.account = account
    }

    public init(_ name: String) {
        if let range = name.range(of: Self.separator) {
            provider = String(name[..<range.lowerBound])
            account = String(name[range.upperBound...])
        } else {
            provider = name
            account = nil
        }
    }

    public var full: String {
        account.map { provider + Self.separator + $0 } ?? provider
    }
}

/// Welche Limits ein Widget zeigt, wenn nicht alle Platz haben.
public enum LimitPick {
    /// Die `count` knappsten Limits, in der Reihenfolge der App; dazu, wie viele wegfallen.
    /// Bei Gleichstand gewinnt das weiter vorn stehende.
    public static func tightest(_ windows: [LimitWindow], count: Int) -> (shown: [LimitWindow], hidden: Int) {
        guard windows.count > count else { return (windows, 0) }
        let keep = windows.indices
            .sorted { windows[$0].percent != windows[$1].percent ? windows[$0].percent > windows[$1].percent : $0 < $1 }
            .prefix(max(count, 0))
        let shown = keep.sorted().map { windows[$0] }
        return (shown, windows.count - shown.count)
    }

    /// Die `count` knappsten Limits, das knappste zuerst (Tabelle X4: knappstes und zweites).
    public static func descending(_ windows: [LimitWindow], count: Int) -> [LimitWindow] {
        windows.indices
            .sorted { windows[$0].percent != windows[$1].percent ? windows[$0].percent > windows[$1].percent : $0 < $1 }
            .prefix(max(count, 0))
            .map { windows[$0] }
    }

    /// Höchstzahl je Größe: klein 2, mittel 4 (zwei Spalten), groß 4 je Abschnitt.
    public static let small = 2
    public static let medium = 4
    public static let section = 4
    /// Knappe Stufen (M3, L2) zeigen je Konto zwei.
    public static let compact = 2
}

/// Texte der Sammelzeilen und Köpfe.
public enum WidgetText {
    /// „+1 Limit“ bzw. „+2 Limits“ – im Abschnittskopf des großen Widgets.
    public static func hiddenLimits(_ count: Int) -> String {
        "+\(count) \(count == 1 ? "Limit" : "Limits")"
    }

    /// „+1 Limit in der App“ – Kopfdetail der knappen Stufe des mittleren Widgets.
    public static func hiddenLimitsInApp(_ count: Int) -> String {
        hiddenLimits(count) + " in der App"
    }

    /// „4 Anbieter“ (ein Konto je Anbieter) bzw. „8 Konten“, sobald ein Name einen Kontoteil hat.
    public static func providerCount(_ providers: [WidgetSnapshot.Provider]) -> String {
        let count = providers.count
        if hasAccounts(providers) {
            return "\(count) \(count == 1 ? "Konto" : "Konten")"
        }
        return "\(count) Anbieter"
    }

    /// „+7 weitere Konten · höchstens 26 %“. Weil die Tabelle absteigend sortiert ist, steckt
    /// darin nie ein knapperes Konto als die gezeigten.
    public static func moreAccounts(_ rest: [WidgetSnapshot.Provider], accounts: Bool) -> String {
        let count = rest.count
        let noun = accounts
            ? (count == 1 ? "weiteres Konto" : "weitere Konten")
            : (count == 1 ? "weiterer Anbieter" : "weitere Anbieter")
        let head = "+\(count) \(noun)"
        guard let highest = rest.compactMap(\.tightestPercent).max() else { return head }
        return "\(head) · höchstens \(Format.percent(highest))"
    }

    /// „+3 weitere Modelle“ unter den Modellzeilen des großen Verbrauchs-Widgets.
    public static func moreModels(_ count: Int) -> String {
        "+\(count) \(count == 1 ? "weiteres Modell" : "weitere Modelle")"
    }

    static func hasAccounts(_ providers: [WidgetSnapshot.Provider]) -> Bool {
        providers.contains { WidgetTitle($0.name).account != nil }
    }
}

/// Die Tabelle des großen Limits-Widgets: eine Zeile je Konto mit seinem knappsten Limit.
public enum LimitsTable {
    /// Konten ohne Stand (Fehler) zuerst, dann nach knappstem Limit absteigend; bei Gleichstand
    /// bleibt die Reihenfolge der App. So steht oben, was Aufmerksamkeit braucht.
    public static func ordered(_ providers: [WidgetSnapshot.Provider]) -> [WidgetSnapshot.Provider] {
        providers.enumerated().sorted { lhs, rhs in
            let left = lhs.element.tightestPercent ?? .infinity
            let right = rhs.element.tightestPercent ?? .infinity
            return left != right ? left > right : lhs.offset < rhs.offset
        }.map(\.element)
    }

    /// Zeilenzahlen der Stufe L4 (Tabelle mit Sammelzeile), von viel nach wenig: n−1 … 4.
    /// Unter fünf Konten gibt es keine Sammelzeile – dann stehen alle in der Tabelle.
    public static let minimumRows = 4

    public static func rowCounts(total: Int) -> [Int] {
        guard total > minimumRows else { return [] }
        return Array((minimumRows...(total - 1)).reversed())
    }
}

/// Modellzeilen des Verbrauchs-Widgets: groß höchstens sechs, dann fünf, vier, drei;
/// extragroß in zwei Spalten höchstens zwölf bis vier. Der Rest steht in der Sammelzeile
/// „+N weitere Modelle“.
public enum ModelRows {
    public static let maximum = 6
    public static let minimum = 3
    public static let extraLargeMaximum = 12
    public static let extraLargeMinimum = 4

    public static func counts(total: Int, maximum: Int = maximum, minimum: Int = minimum) -> [Int] {
        guard total > minimum else { return [max(total, 0)] }
        return Array((minimum...min(total, maximum)).reversed())
    }
}

/// Zwei Spalten im extragroßen Widget.
public enum ColumnSplit {
    /// Abschnitte zweispaltig (X2/X3): Wie viele kommen nach links, damit die höhere Spalte so
    /// niedrig wie möglich ist? Die Reihenfolge bleibt (links oben nach unten, dann rechts).
    /// Bei Gleichstand links mehr.
    public static func balanced(_ heights: [Double], spacing: Double) -> Int {
        guard heights.count > 1 else { return heights.count }
        func column(_ part: ArraySlice<Double>) -> Double {
            part.isEmpty ? 0 : part.reduce(0, +) + spacing * Double(part.count - 1)
        }
        var best = heights.count, bestHeight = Double.infinity
        for left in (1...heights.count).reversed() {
            let height = max(column(heights[..<left]), column(heights[left...]))
            if height < bestHeight - 0.001 {
                best = left
                bestHeight = height
            } else if abs(height - bestHeight) < 0.001 {
                best = max(best, left)
            }
        }
        return best
    }

    /// Tabellen nebeneinander (X5), spaltenweise gefüllt: links die ersten ⌈k/2⌉.
    public static func halves(_ count: Int) -> Int {
        (count + 1) / 2
    }
}

extension WidgetSnapshot.Provider {
    /// Auslastung des knappsten Limits; `nil`, wenn es keinen Stand gibt (Fehlerkonto).
    public var tightestPercent: Double? {
        snapshot?.tightestWindow?.percent
    }

    /// Kein Stand, nur ein Hinweis („Anmeldung abgelaufen“) – im großen Widget sichtbar, in der
    /// Tabelle oben.
    public var isFailing: Bool {
        snapshot == nil
    }
}
