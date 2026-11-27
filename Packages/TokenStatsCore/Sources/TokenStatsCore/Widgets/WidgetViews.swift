import SwiftUI

/// Widget-Größen ohne WidgetKit-Abhängigkeit, damit die Views auch in der App (Screenshots)
/// und später auf iOS gerendert werden können.
public enum WidgetSize: Sendable {
    case small, medium, large
}

/// Ohne Daten (App noch nie gestartet) statt Nullwerten.
public struct WidgetPlaceholder: View {
    public init() {}

    public var body: some View {
        VStack(spacing: 8) {
            RobotIcon(size: 22)
            Text("Token Stats öffnen")
                .font(.system(size: 12, weight: .semibold))
            Text("Die App liefert den Stand.")
                .font(.system(size: 10.5))
                .foregroundStyle(.secondary)
        }
        .multilineTextAlignment(.center)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Kopfzeile der Widgets: Roboter · Titel · rechts der Zustandspunkt des knappsten Limits.
///
/// Nichts wird gekürzt (SPEC §6). Passt nicht alles in eine Zeile, nimmt der Kopf die erste
/// passende Form: Details unter dem Titel; Titel am „·“ geteilt („Claude ·“ / „Kunde A“);
/// Kontoname zweizeilig mit „Claude · Tarif“ darunter; erst zuletzt freier Umbruch. So hat ein
/// Kontoname bis 24 Zeichen höchstens zwei Titelzeilen. Die Stufen S1–S8 aus „Widgets
/// einheitlich“ (#4) ersetzen das später.
struct WidgetHeader: View {
    let title: String
    let detail: String?
    let severity: Severity?
    /// Pflichtdetail, das nie wegfällt und eine eigene Zeile über dem Tarif bekommt:
    /// „knappstes Konto“, wenn das gezeigte Konto von selbst wechselt.
    var selection: String? = nil

    private static let titleFont = Font.system(size: 12, weight: .bold)
    private static let detailFont = Font.system(size: 10.5)

    var body: some View {
        let parts = title.components(separatedBy: " · ")
        let kind = parts.count > 1 ? parts[0] : nil
        let account = parts.count > 1 ? parts.dropFirst().joined(separator: " · ") : nil
        let splits = account.map(Self.twoLineSplits) ?? []
        ViewThatFits(in: .horizontal) {
            // Eine Zeile.
            row(alignment: .center, dot: true) {
                HStack(spacing: 6) {
                    line(title, Self.titleFont)
                    if let inline = [selection, detail].compactMap({ $0 }).joined(separator: " · ").nilIfEmpty {
                        line(inline, Self.detailFont).foregroundStyle(.secondary)
                    }
                }
            }
            // Titel in einer Zeile, Details darunter.
            row(dot: true) { stack([line(title, Self.titleFont)], details: [selection, detail], dot: false) }
            // Erst mit Punkt rechts im Kopf, dann mit Punkt in der Detailzeile (Titel 12 pt breiter).
            // Kandidaten: Titel am „·“ („Claude ·“ / „Kunde A“), dann der Kontoname zweizeilig an
            // Leerzeichen oder Bindestrich mit „Claude · Tarif“ darunter.
            if let kind, let account {
                ForEach(Self.candidates(splits: splits.count), id: \.self) { candidate in
                    let dotInRow = candidate.dotInRow
                    row(dot: dotInRow) {
                        if let index = candidate.split {
                            stack([line(splits[index][0], Self.titleFont), line(splits[index][1], Self.titleFont)],
                                  details: [selection, [kind, detail].compactMap { $0 }.joined(separator: " · ")],
                                  dot: !dotInRow)
                        } else {
                            stack([line(kind + " ·", Self.titleFont), line(account, .system(size: 12))],
                                  details: [selection, detail], dot: !dotInRow)
                        }
                    }
                }
            }
            // Letzter Ausweg: Umbruch nur an Leerzeichen und Bindestrichen, nie mitten im Wort.
            row(dot: false) {
                VStack(alignment: .leading, spacing: 1) {
                    TokenFlow(spacing: 0) {
                        ForEach(Array(Self.breakTokens(title).enumerated()), id: \.offset) { _, token in
                            Text(token).font(Self.titleFont).lineLimit(1).fixedSize()
                        }
                    }
                    stackDetails([selection, detail], dot: true)
                }
            }
        }
    }

    private func row(alignment: VerticalAlignment = .top, dot: Bool, @ViewBuilder _ content: () -> some View) -> some View {
        HStack(alignment: alignment, spacing: 6) {
            RobotIcon(size: 13)
            content()
            if dot {
                Spacer(minLength: 6)
                circle.padding(.top, alignment == .top ? 4 : 0)
            }
        }
    }

    @ViewBuilder private var circle: some View {
        if let severity {
            Circle().fill(severity.color).frame(width: 7, height: 7)
        }
    }

    private func stack(_ titleLines: [AnyView], details: [String?], dot: Bool) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            ForEach(titleLines.indices, id: \.self) { titleLines[$0] }
            stackDetails(details, dot: dot)
        }
    }

    /// Detailzeilen; mit `dot` steht der Zustandspunkt rechts in der ersten (Stufe S7).
    @ViewBuilder
    private func stackDetails(_ details: [String?], dot: Bool) -> some View {
        let lines = details.compactMap { $0?.nilIfEmpty }
        ForEach(lines.indices, id: \.self) { index in
            HStack(spacing: 6) {
                line(lines[index], Self.detailFont).foregroundStyle(.secondary)
                if dot, index == 0, severity != nil {
                    Spacer(minLength: 6)
                    circle
                }
            }
        }
        if dot, lines.isEmpty, severity != nil {
            HStack { Spacer(minLength: 6); circle }
        }
    }

    /// Eine Zeile, die nie umbricht – passt sie nicht, scheitert die Form (`ViewThatFits`).
    private func line(_ text: String, _ font: Font) -> AnyView {
        AnyView(Text(text).font(font).lineLimit(1).fixedSize())
    }

    /// Eine Form des zweizeiligen Titels; `split == nil` = Teilung am „·“.
    struct Candidate: Hashable {
        var dotInRow: Bool
        var split: Int?
    }

    static func candidates(splits: Int) -> [Candidate] {
        [true, false].flatMap { dot in
            [Candidate(dotInRow: dot, split: nil)] + (0..<splits).map { Candidate(dotInRow: dot, split: $0) }
        }
    }

    /// Stellen, an denen ein Name umbrechen darf: nach einem Leerzeichen oder Bindestrich.
    /// „Kunde Schmidt Beratung“ → „Kunde “, „Schmidt “, „Beratung“.
    static func breakTokens(_ text: String) -> [String] {
        var tokens: [String] = []
        var current = ""
        for character in text {
            current.append(character)
            if character == " " || character == "-" {
                tokens.append(current)
                current = ""
            }
        }
        if !current.isEmpty { tokens.append(current) }
        return tokens
    }

    /// Alle Teilungen in zwei Zeilen an erlaubten Stellen, die längere erste Zeile zuerst.
    static func twoLineSplits(_ text: String) -> [[String]] {
        let tokens = breakTokens(text)
        guard tokens.count > 1 else { return [] }
        return (1..<tokens.count).reversed().map { split in
            [tokens[..<split].joined().trimmingCharacters(in: .whitespaces),
             tokens[split...].joined().trimmingCharacters(in: .whitespaces)]
        }
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}

/// „work · vor 12 Min.“ – nur für Stände, die über iCloud von einem Mac kamen.
struct MachineFooter: View {
    let snapshot: WidgetSnapshot

    var body: some View {
        if let machine = snapshot.machine {
            (Text(machine) + Text(" · vor ") + Text(snapshot.writtenAt, style: .relative))
                .font(.system(size: 9.5))
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }
}

// MARK: - Verbrauch

/// Widget „Verbrauch“: Tokens und API-Vergleichswert für einen Zeitraum (Issue #10).
public struct UsageWidgetView: View {
    public let snapshot: WidgetSnapshot?
    /// `nil` = alle Anbieter zusammen.
    public let provider: String?
    public let period: UsagePeriod
    public let size: WidgetSize

    public init(snapshot: WidgetSnapshot?, provider: String?, period: UsagePeriod, size: WidgetSize) {
        self.snapshot = snapshot
        self.provider = provider
        self.period = period
        self.size = size
    }

    public var body: some View {
        if let snapshot {
            content(snapshot)
        } else {
            WidgetPlaceholder()
        }
    }

    private var title: String {
        provider.flatMap { snapshot?.providerName(kind: $0) } ?? "Verbrauch"
    }

    @ViewBuilder
    private func content(_ snapshot: WidgetSnapshot) -> some View {
        let summary = snapshot.summary(provider: provider, period: period) ?? UsageSummary()
        let severity = snapshot.tightest?.window.severity
        VStack(alignment: .leading, spacing: size == .small ? 6 : 10) {
            WidgetHeader(title: title, detail: period.label, severity: severity)
            if summary.total.isZero {
                Spacer(minLength: 0)
                Text("Keine Einträge in diesem Zeitraum.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                Spacer(minLength: 0)
            } else {
                switch size {
                case .small: small(summary, showMoney: snapshot.showMoney)
                case .medium: medium(summary, showMoney: snapshot.showMoney)
                case .large: large(summary, showMoney: snapshot.showMoney)
                }
            }
            MachineFooter(snapshot: snapshot)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func small(_ summary: UsageSummary, showMoney: Bool) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Spacer(minLength: 0)
            Stat(title: "Tokens", value: Format.tokens(summary.total.total),
                 detail: "\(Format.tokens(summary.total.cacheRead)) Cache-Lesen", large: true)
            if showMoney {
                Stat(title: "API-Vergleichswert", value: Format.money(summary.value) + (summary.hasUnpriced ? "*" : ""),
                     detail: nil, large: false)
            }
        }
    }

    private func medium(_ summary: UsageSummary, showMoney: Bool) -> some View {
        HStack(alignment: .top, spacing: 14) {
            VStack(alignment: .leading, spacing: 8) {
                Stat(title: "Tokens", value: Format.tokens(summary.total.total),
                     detail: "\(Format.tokens(summary.total.cacheRead)) davon Cache-Lesen", large: true)
                if showMoney {
                    Stat(title: "API-Vergleichswert", value: Format.money(summary.value) + (summary.hasUnpriced ? "*" : ""),
                         detail: nil, large: true)
                }
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            chartOrShare(summary)
                .frame(maxWidth: .infinity)
        }
    }

    private func large(_ summary: UsageSummary, showMoney: Bool) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 14) {
                Stat(title: "Tokens", value: Format.tokens(summary.total.total),
                     detail: "\(Format.tokens(summary.total.cacheRead)) davon Cache-Lesen", large: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if showMoney {
                    Stat(title: "API-Vergleichswert", value: Format.money(summary.value) + (summary.hasUnpriced ? "*" : ""),
                         detail: "berechnet, keine Kosten", large: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            if summary.days.count > 1 {
                DayChart(days: summary.days, compact: true).frame(height: 44)
            }
            VStack(spacing: 0) {
                ForEach(summary.models.prefix(6)) { line in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(ModelName.display(line.model)).font(.system(size: 11, weight: .semibold))
                        Text("\(Format.tokens(line.counts.input)) in · \(Format.tokens(line.counts.output)) out · \(Format.tokens(line.counts.cache)) Cache")
                            .font(.system(size: 9.5))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                        Spacer(minLength: 4)
                        if showMoney {
                            Text(line.value.map(Format.money) ?? "ohne Preis")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(line.value == nil ? .secondary : .primary)
                        }
                    }
                    .monospacedDigit()
                    .padding(.vertical, 4)
                    Divider()
                }
                if summary.models.count > 6 {
                    Text("+\(summary.models.count - 6) weitere Modelle")
                        .font(.system(size: 9.5))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.top, 4)
                }
            }
            Spacer(minLength: 0)
        }
    }

    /// Mehrtägige Zeiträume zeigen das Tagesdiagramm, „Heute“ den Cache-Anteil.
    @ViewBuilder
    private func chartOrShare(_ summary: UsageSummary) -> some View {
        if summary.days.count > 1 {
            DayChart(days: summary.days, compact: true)
        } else {
            VStack(alignment: .leading, spacing: 8) {
                Stat(title: "Input", value: Format.tokens(summary.total.input), detail: nil, large: false)
                Stat(title: "Output", value: Format.tokens(summary.total.output), detail: nil, large: false)
                Stat(title: "Cache", value: Format.tokens(summary.total.cache), detail: nil, large: false)
                Spacer(minLength: 0)
            }
        }
    }
}

private struct Stat: View {
    let title: String
    let value: String
    let detail: String?
    let large: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title.uppercased())
                .font(.system(size: 9))
                .tracking(0.5)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.system(size: large ? 20 : 14, weight: .bold))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            if let detail {
                Text(detail)
                    .font(.system(size: 9.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
    }
}

// MARK: - Limits

/// Widget „Limits“: die Meter eines Anbieters mit Pace-Marke, wie auf der Seite „Limits“.
public struct LimitsWidgetView: View {
    public let snapshot: WidgetSnapshot?
    /// `nil` = der Anbieter mit dem knappsten Limit.
    public let provider: String?
    public let size: WidgetSize
    public var now: Date

    public init(snapshot: WidgetSnapshot?, provider: String?, size: WidgetSize, now: Date = .now) {
        self.snapshot = snapshot
        self.provider = provider
        self.size = size
        self.now = now
    }

    public var body: some View {
        if let snapshot {
            content(snapshot)
        } else {
            WidgetPlaceholder()
        }
    }

    /// Welches Konto gezeigt wird – gewählt oder das knappste, sonst das erste mit Stand.
    /// Ein gewähltes Konto, das nicht im Stand steht, ergibt `nil` (kein stiller Wechsel).
    public static func resolve(_ snapshot: WidgetSnapshot, provider: String?) -> WidgetSnapshot.Provider? {
        if let provider { return snapshot.provider(provider) }
        return snapshot.tightest?.provider ?? snapshot.providers.first { $0.snapshot != nil } ?? snapshot.providers.first
    }

    /// Pflichtdetail bei „Claude – knappstes Konto“: Das gezeigte Konto wechselt von selbst.
    private var selectionDetail: String? {
        provider.flatMap(LimitsAccounts.tightestKind) == nil ? nil : "knappstes\u{00A0}Konto"
    }

    @ViewBuilder
    private func content(_ snapshot: WidgetSnapshot) -> some View {
        switch size {
        case .large:
            VStack(alignment: .leading, spacing: 12) {
                if snapshot.providers.allSatisfy({ $0.snapshot == nil }) {
                    WidgetHeader(title: "Limits", detail: nil, severity: nil)
                    noData(snapshot.providers.first)
                } else {
                    large(snapshot)
                }
                Spacer(minLength: 0)
                MachineFooter(snapshot: snapshot)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        case .medium, .small:
            let shown = Self.resolve(snapshot, provider: provider)
            VStack(alignment: .leading, spacing: 8) {
                if let shown, let windows = shown.snapshot?.windows {
                    // Passt nicht jedes Limit (langer Kontoname, kleine Kachel), lieber eins weniger
                    // als ein abgeschnittenes – gezeigt werden dann die knappsten.
                    let most = min(windows.count, size == .medium ? 4 : 2)
                    ViewThatFits(in: .vertical) {
                        ForEach(Array((1...max(most, 1)).reversed()), id: \.self) { count in
                            VStack(alignment: .leading, spacing: 8) {
                                section(shown, columns: size == .medium ? 2 : 1, maxWindows: count, compact: true)
                            }
                        }
                    }
                } else if let shown {
                    WidgetHeader(title: shown.name, detail: nil, severity: nil, selection: selectionDetail)
                    noData(shown)
                } else if let provider {
                    // Gewähltes Konto steht nicht im Stand: beim Namen nennen, nie als `claude@…`.
                    WidgetHeader(title: LimitsAccounts.choice(for: provider, in: snapshot).title, detail: nil, severity: nil)
                    note(LimitsAccounts.missingMessage)
                } else {
                    WidgetHeader(title: "Limits", detail: nil, severity: nil)
                    noData(nil)
                }
                Spacer(minLength: 0)
                MachineFooter(snapshot: snapshot)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }

    private func noData(_ provider: WidgetSnapshot.Provider?) -> some View {
        note(provider?.message ?? "Noch kein Stand – Token Stats fragt beim nächsten Takt ab.")
    }

    /// Großes Widget, alle sichtbaren Konten: erst Abschnitte mit allen Limits, passt das
    /// nicht, die Tabelle mit allen Konten, dann mit Sammelzeile – nichts fällt still weg.
    @ViewBuilder
    private func large(_ snapshot: WidgetSnapshot) -> some View {
        let rows = LimitsAccounts.rows(snapshot)
        let header = WidgetHeader(title: "Limits", detail: LimitsAccounts.countText(snapshot),
                                  severity: snapshot.tightest?.window.severity)
        // Mindestens vier Zeilen, sonst lieber die Abschnitte (Entwurf L4: k = n−1 … 4).
        let partial = rows.count > 5 ? Array((4...(rows.count - 1)).reversed()) : []
        ViewThatFits(in: .vertical) {
            VStack(alignment: .leading, spacing: 12) {
                ForEach(snapshot.providers) { provider in
                    if provider.snapshot != nil {
                        section(provider, columns: 2, maxWindows: 4, compact: true)
                    } else {
                        VStack(alignment: .leading, spacing: 6) {
                            WidgetHeader(title: provider.name, detail: nil, severity: nil)
                            noData(provider)
                        }
                    }
                }
            }
            VStack(alignment: .leading, spacing: 8) {
                header
                LimitsAccountTable(rows: rows, shown: rows.count, now: now)
            }
            ForEach(partial, id: \.self) { shown in
                VStack(alignment: .leading, spacing: 8) {
                    header
                    LimitsAccountTable(rows: rows, shown: shown, now: now)
                }
            }
            VStack(alignment: .leading, spacing: 8) {
                header
                LimitsAccountTable(rows: rows, shown: min(rows.count, 4), now: now)
            }
        }
    }

    private func note(_ text: String) -> some View {
        CommandText(text)
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func section(_ provider: WidgetSnapshot.Provider, columns: Int, maxWindows: Int, compact: Bool) -> some View {
        // Ist kein Platz für alle, die knappsten – in der Reihenfolge der App.
        let all = provider.snapshot?.windows ?? []
        let keep = Set(all.enumerated().sorted { $0.element.percent != $1.element.percent ? $0.element.percent > $1.element.percent : $0.offset < $1.offset }
            .prefix(maxWindows).map(\.element.id))
        let windows = all.filter { keep.contains($0.id) }
        // Die Spalten sind schmal; der Zusatz „7 d, alle Modelle“ passt nur im großen Widget.
        let showScope = size == .large
        WidgetHeader(
            title: provider.name,
            detail: provider.isRateLimited ? "Abfrage pausiert" : provider.snapshot?.account?.plan,
            severity: provider.snapshot?.tightestWindow?.severity,
            selection: size == .large ? nil : selectionDetail
        )
        if columns == 1 {
            ForEach(windows) { MeterRow(window: $0, compact: compact, showScope: showScope, stackDetails: true, now: now) }
        } else {
            let rows = stride(from: 0, to: windows.count, by: columns).map { Array(windows[$0..<min($0 + columns, windows.count)]) }
            ForEach(rows.indices, id: \.self) { index in
                HStack(alignment: .top, spacing: 14) {
                    ForEach(rows[index]) { MeterRow(window: $0, compact: compact, showScope: showScope, now: now) }
                    if rows[index].count < columns {
                        Color.clear.frame(maxWidth: .infinity)
                    }
                }
            }
        }
    }
}
