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
/// passende Form: Details unter dem Titel; Titel am „·“ geteilt („Claude“ / „· Kunde A“);
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
            // Titel in einer Zeile, Details darunter. Beim knappsten Konto nicht: Dort steht in
            // jeder Stufe zuerst der Kontoname, dann „knappstes Konto“, dann „Claude · Tarif“.
            // Jede Form gibt es mit den Details in einer Zeile, mit „+N Limits“ in eigener Zeile
            // und mit jedem Detail in eigener Zeile (`detailVariants`).
            if selection == nil {
                ForEach(0..<Self.detailVariantCount, id: \.self) { variant in
                    row(dot: false) {
                        stack([line(title, Self.titleFont)], details: Self.detailVariant([selection, detail], variant),
                              dot: false, dotOnTitle: true)
                    }
                }
            }
            // Erst mit Punkt rechts im Kopf, dann mit Punkt in der Detailzeile (Titel 12 pt breiter).
            // Kandidaten: Titel am „·“ („Claude“ / „· Kunde A“), dann der Kontoname zweizeilig an
            // Leerzeichen oder Bindestrich mit „Claude · Tarif“ darunter.
            if let kind, let account {
                ForEach(Self.candidates(splits: splits.count, accountFirst: selection != nil), id: \.self) { candidate in
                    let dotInRow = candidate.dotInRow
                    // Der Punkt steht in der ersten Titelzeile, nicht neben dem ganzen Block: So
                    // begrenzt er nur die Titelzeile, und die Details dürfen die volle Breite nutzen.
                    row(dot: false) {
                        let kindDetails = Self.detailVariant([selection, [kind, detail].compactMap { $0 }.joined(separator: " · ")],
                                                             candidate.details)
                        if candidate.accountLine {
                            stack([line(account, Self.titleFont)], details: kindDetails, dot: !dotInRow, dotOnTitle: dotInRow)
                        } else if let index = candidate.split {
                            stack([line(splits[index][0], Self.titleFont), line(splits[index][1], Self.titleFont)],
                                  details: kindDetails, dot: !dotInRow, dotOnTitle: dotInRow)
                        } else {
                            // Der Trennpunkt beginnt die zweite Zeile („Claude“ / „· Kunde A“), statt
                            // am Zeilenende zu hängen (Designer-Prüfung PR #5, Runde 5).
                            stack([line(kind, Self.titleFont), line("· " + account, .system(size: 12))],
                                  details: Self.detailVariant([selection, detail], candidate.details),
                                  dot: !dotInRow, dotOnTitle: dotInRow)
                        }
                    }
                }
            }
            // Letzter Ausweg: Titel bricht nur an Leerzeichen und Bindestrichen um, die Details an
            // „ · “ und Leerzeichen; nie mitten im Wort und nie breiter als die Kachel – sonst
            // drückt eine zu lange Detailzeile („Max 20× · +2 Limits“) den Inhalt an den rechten
            // Rand (Designer-Prüfung PR #5, Runde 3).
            // Wie Stufe S6–S8 des Entwurfs: im letzten Ausweg ist der Kontoname der Titel, „Claude · Tarif“
            // steht in der Detailzeile – das spart eine Titelzeile (z. B. „MÖBELWERKSTATT“).
            let accountFirst = kind != nil && account != nil
            // Der Punkt steht hier rechts in der ersten Detailzeile (wie Stufe S7), damit der
            // Titel die volle Breite hat – sonst ragte „· kundenbetreuung-“ in den Innenrand.
            row(dot: false) {
                VStack(alignment: .leading, spacing: 1) {
                    // Gemessener Umbruch: Trennpunkt vorn, wenn „· Name“ passt, sonst am Zeilenende;
                    // zu breite Einzelwörter („MÖBELWERKSTATT“) brechen zuletzt zeichenweise.
                    WrappedTitle(accountFirst ? account! : title, size: 12)
                    let details = (accountFirst ? [selection, [kind!, detail].compactMap { $0 }.joined(separator: " · ")] : [selection, detail])
                        .compactMap { $0?.nilIfEmpty }
                    ForEach(details.indices, id: \.self) { index in
                        // spacing 0: Der Abstand zum Punkt kommt nur vom Spacer (Entwurf §3: sonst
                        // werden aus 6 pt 12 pt und „Claude · Max 5×“ bricht um).
                        HStack(alignment: .top, spacing: 0) {
                            TokenFlow(spacing: Self.detailSpace) {
                                ForEach(Array(Self.detailTokens(details[index]).enumerated()), id: \.offset) { _, token in
                                    Text(token).font(Self.detailFont).foregroundStyle(.secondary).lineLimit(1).fixedSize()
                                }
                            }
                            // Erst die Details, dann der Abstand zum Punkt – sonst teilt der HStack
                            // die Breite auf, und „Claude · Max 5×“ bricht unnötig um.
                            .layoutPriority(1)
                            if index == 0, severity != nil {
                                Spacer(minLength: 6)
                                circle.padding(.top, 3)
                            }
                        }
                    }
                    if details.isEmpty, severity != nil {
                        HStack(spacing: 0) { Spacer(minLength: 6); circle }
                    }
                }
            }
        }
    }

    /// Stellen, an denen eine Detailzeile umbrechen darf: nach „ · “, sonst nach Leerzeichen,
    /// wobei „+2 Limits“ und „Max 20×“ zusammenbleiben.
    nonisolated static func detailTokens(_ text: String) -> [String] {
        // Der Trennpunkt beginnt den nächsten Teil („Max 20×“ / „· +2 Limits“), wie im Titel.
        // Kein Leerzeichen am Ende: Den Abstand setzt `TokenFlow` (`detailSpace`), und am
        // Zeilenende zählt er nicht mit.
        let parts = text.components(separatedBy: " · ")
        return parts.enumerated().map { index, part in (index == 0 ? "" : "· ") + part }
    }

    /// Breite eines Leerzeichens in der Detailschrift – Abstand zwischen zwei Detail-Teilen.
    nonisolated static let detailSpace: CGFloat = TextWidth.measure([(" ", .regular)], size: 10.5)

    private func row(alignment: VerticalAlignment = .top, dot: Bool, @ViewBuilder _ content: () -> some View) -> some View {
        // Abstände ausdrücklich, ohne Stack-Spacing obendrauf (Entwurf §3): Icon → Titel 6,
        // Inhalt → Punkt mindestens 6.
        HStack(alignment: alignment, spacing: 0) {
            RobotIcon(size: 13)
            content().padding(.leading, 6)
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

    private func stack(_ titleLines: [AnyView], details: [String?], dot: Bool, dotOnTitle: Bool = false) -> some View {
        // Kein Zusatzabstand zwischen den Kopfzeilen: Der Zeilenabstand der Schrift reicht, und
        // in der kleinsten Kachel zählt jeder Punkt (Entwurf „Widgets einheitlich“ §4.1).
        VStack(alignment: .leading, spacing: 0) {
            ForEach(titleLines.indices, id: \.self) { index in
                if index == 0, dotOnTitle, severity != nil {
                    HStack(spacing: 0) {
                        titleLines[index]
                        Spacer(minLength: 6)
                        circle
                    }
                } else {
                    titleLines[index]
                }
            }
            stackDetails(details, dot: dot)
        }
    }

    /// Detailzeilen; mit `dot` steht der Zustandspunkt rechts in der ersten (Stufe S7).
    @ViewBuilder
    private func stackDetails(_ details: [String?], dot: Bool) -> some View {
        let lines = details.compactMap { $0?.nilIfEmpty }
        ForEach(lines.indices, id: \.self) { index in
            HStack(spacing: 0) {
                // Einzeilige Detailzeile in fester Höhe 12 pt (Entwurf §4.1); die Glyphen passen.
                line(lines[index], Self.detailFont).foregroundStyle(.secondary).frame(height: 12)
                if dot, index == 0, severity != nil {
                    Spacer(minLength: 6)
                    circle
                }
            }
        }
        if dot, lines.isEmpty, severity != nil {
            HStack(spacing: 0) { Spacer(minLength: 6); circle }
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
        /// Kontoname einzeilig als Titel, „Claude · Tarif“ darunter.
        var accountLine = false
        /// Welche Variante der Detailzeilen (`detailVariant`).
        var details = 0
    }

    /// `accountFirst` beim knappsten Konto: statt der Teilung am „·“ der Kontoname als Titel.
    /// Je Titelform zuerst die Details in einer Zeile, dann aufgeteilt.
    static func candidates(splits: Int, accountFirst: Bool = false) -> [Candidate] {
        [true, false].flatMap { dot in
            ([Candidate(dotInRow: dot, split: nil, accountLine: accountFirst)]
                + (0..<splits).map { Candidate(dotInRow: dot, split: $0) })
                .flatMap { form in (0..<detailVariantCount).map { var c = form; c.details = $0; return c } }
        }
    }

    static let detailVariantCount = 3

    /// Detailzeilen in drei Stufen: wie gegeben; der letzte Teil der letzten Zeile („+2 Limits“)
    /// in eigener Zeile; jeder Teil in eigener Zeile. Nie ein Bruch mitten in einem Teil.
    nonisolated static func detailVariant(_ details: [String?], _ variant: Int) -> [String?] {
        let lines = details.compactMap { $0?.nilIfEmpty }
        switch variant {
        case 0:
            return lines
        case 1:
            guard let last = lines.last, let range = last.range(of: " · ", options: .backwards) else { return lines }
            // Der Trennpunkt beginnt die neue Zeile, wie überall („Max 20×“ / „· +1 Limit“).
            return lines.dropLast() + [String(last[..<range.lowerBound]), "· " + String(last[range.upperBound...])]
        default:
            return lines.flatMap { line in
                line.components(separatedBy: " · ").enumerated().map { $0.offset == 0 ? $0.element : "· " + $0.element }
            }
        }
    }

    /// Stellen, an denen ein Name umbrechen darf: nach einem Leerzeichen oder Bindestrich.
    /// „Kunde Schmidt Beratung“ → „Kunde “, „Schmidt “, „Beratung“.
    nonisolated static func breakTokens(_ text: String) -> [String] {
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
        // Der Trennpunkt gehört zum folgenden Teil („· Kunde “) – für die zweizeiligen Teilungen.
        // Den freien Umbruch mit Messung übernimmt `TitleWrap`.
        var merged: [String] = []
        var pending = ""
        for token in tokens {
            if token == "· " { pending += token; continue }
            merged.append(pending + token)
            pending = ""
        }
        if !pending.isEmpty { merged.append(pending) }
        return merged
    }

    /// Alle Teilungen in zwei Zeilen an erlaubten Stellen, die längere erste Zeile zuerst.
    nonisolated static func twoLineSplits(_ text: String) -> [[String]] {
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
    public nonisolated static func resolve(_ snapshot: WidgetSnapshot, provider: String?) -> WidgetSnapshot.Provider? {
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
            VStack(alignment: .leading, spacing: 0) {
                if snapshot.providers.allSatisfy({ $0.snapshot == nil }) {
                    headedNote(WidgetHeader(title: "Limits", detail: nil, severity: nil), noDataText(snapshot.providers.first))
                } else {
                    // Breite messen: Die Tabelle wählt danach Stufe L5, statt im Wort zu brechen.
                    GeometryReader { geometry in
                        large(snapshot, width: geometry.size.width)
                    }
                }
                // Abstand zur Fußzeile nur, wenn es eine gibt (Stand über iCloud) – sonst kostete
                // die leere Fußzeile unten 2 × 12 pt (Designer-Prüfung PR #5, Runde 9).
                Spacer(minLength: 0)
                if snapshot.machine != nil {
                    MachineFooter(snapshot: snapshot).padding(.top, 12)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        case .medium, .small:
            let shown = Self.resolve(snapshot, provider: provider)
            VStack(alignment: .leading, spacing: 0) {
                if let shown, let windows = shown.snapshot?.windows {
                    // Passt nicht jedes Limit (langer Kontoname, kleine Kachel), lieber eins weniger
                    // als ein abgeschnittenes – gezeigt werden dann die knappsten.
                    let most = min(windows.count, size == .medium ? 4 : 2)
                    ViewThatFits(in: .vertical) {
                        // Zuletzt nur der Kopf mit „+N Limits“ – lieber kein Meter als ein abgeschnittener.
                        ForEach(Array((0...max(most, 1)).reversed()), id: \.self) { count in
                            VStack(alignment: .leading, spacing: 8) {
                                section(shown, columns: size == .medium ? 2 : 1, maxWindows: count, compact: true)
                            }
                        }
                    }
                } else if let shown {
                    headedNote(WidgetHeader(title: shown.name, detail: nil, severity: nil, selection: selectionDetail),
                               noDataText(shown))
                } else if let provider {
                    // Gewähltes Konto steht nicht im Stand: beim Namen nennen, nie als `claude@…`.
                    headedNote(WidgetHeader(title: LimitsAccounts.choice(for: provider, in: snapshot).title, detail: nil, severity: nil),
                               LimitsAccounts.missingMessage)
                } else {
                    headedNote(WidgetHeader(title: "Limits", detail: nil, severity: nil), noDataText(nil))
                }
                Spacer(minLength: 0)
                if snapshot.machine != nil {
                    MachineFooter(snapshot: snapshot).padding(.top, 8)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }

    private func noData(_ provider: WidgetSnapshot.Provider?) -> some View {
        note(noDataText(provider))
    }

    private func noDataText(_ provider: WidgetSnapshot.Provider?) -> String {
        provider?.message ?? "Noch kein Stand – Token Stats fragt beim nächsten Takt ab."
    }

    /// Kopf und Hinweis mit Ausweichstufen (`CommandSplit.shortVariants`): Passt der volle Satz
    /// nicht in die Kachel, steht der kürzere da – nie ragt Text in den unteren Innenrand
    /// (Designer-Prüfung PR #5, Runde 4: „keine Anmeldung“ in der kleinsten Kachel).
    private func headedNote(_ header: WidgetHeader, _ text: String) -> some View {
        ViewThatFits(in: .vertical) {
            ForEach(CommandSplit.shortVariants(text), id: \.self) { variant in
                VStack(alignment: .leading, spacing: 8) {
                    header
                    note(variant)
                }
            }
        }
    }

    /// Großes Widget, alle sichtbaren Konten: erst Abschnitte mit allen Limits, passt das
    /// nicht, die Tabelle mit allen Konten, dann mit Sammelzeile – nichts fällt still weg.
    @ViewBuilder
    private func large(_ snapshot: WidgetSnapshot, width: CGFloat) -> some View {
        let rows = LimitsAccounts.rows(snapshot)
        let stacked = LimitsAccountTable.needsStacked(rows, total: width)
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
                LimitsAccountTable(rows: rows, shown: rows.count, now: now, stacked: stacked)
            }
            ForEach(partial, id: \.self) { shown in
                VStack(alignment: .leading, spacing: 8) {
                    header
                    LimitsAccountTable(rows: rows, shown: shown, now: now, stacked: stacked)
                }
            }
            VStack(alignment: .leading, spacing: 8) {
                header
                LimitsAccountTable(rows: rows, shown: min(rows.count, 4), now: now, stacked: stacked)
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
        // Ist kein Platz für alle, die knappsten – in der Reihenfolge der App; die übrigen
        // stehen als „+N Limits“ im Kopf.
        let picked = LimitsAccounts.pick(provider.snapshot?.windows ?? [], maximum: maxWindows)
        let windows = picked.shown
        // Die Spalten sind schmal; der Zusatz „7 d, alle Modelle“ passt nur im großen Widget.
        let showScope = size == .large
        let plan = provider.isRateLimited ? "Abfrage pausiert" : provider.snapshot?.account?.plan
        WidgetHeader(
            title: provider.name,
            detail: [plan, LimitsAccounts.hiddenLimitsText(picked.hidden)].compactMap { $0 }.joined(separator: " · ").nilIfEmpty,
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
