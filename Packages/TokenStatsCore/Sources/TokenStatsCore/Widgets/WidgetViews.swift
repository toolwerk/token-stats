import SwiftUI

// Widget-Views „Verbrauch“ und „Limits“ (SPEC §7 „Widgets“). Jede Größe hat eine Stufenleiter
// von reich nach knapp; `ViewThatFits(in: .vertical)` nimmt die erste, die ganz passt. Kein
// eigener Außenrand (das System setzt ihn), kein `minimumScaleFactor`, keine „…“.

/// Widget-Größen ohne WidgetKit-Abhängigkeit, damit die Views auch in der App (Screenshots)
/// und auf iOS gerendert werden können. Extragroß gibt es auf dem Mac nur auf dem Schreibtisch.
public enum WidgetSize: Sendable {
    case small, medium, large, extraLarge

    /// Groß und extragroß zeigen alle Konten, klein und mittel genau eines.
    public var showsAllAccounts: Bool {
        self == .large || self == .extraLarge
    }
}

/// Ohne Daten (App noch nie gestartet) statt Nullwerten.
public struct WidgetPlaceholder: View {
    public init() {}

    public var body: some View {
        VStack(spacing: WidgetSpace.medium) {
            RobotIcon(size: WidgetMetric.placeholderRobot)
            VStack(spacing: 2) {
                Text("Token Stats öffnen").token(.title)
                Text("Die App liefert den Stand.").token(.note).foregroundStyle(.secondary)
            }
            .fixedSize(horizontal: false, vertical: true)
        }
        .multilineTextAlignment(.center)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Stufenleiter: die erste Stufe, die ganz passt. Die letzte Stufe darf nicht scheitern – sie
/// wird lieber am Rand abgeschnitten als leer gezeigt, und nur sie darf mitten im Wort brechen.
struct StageLadder<Stages: View, Last: View>: View {
    @ViewBuilder var stages: Stages
    @ViewBuilder var last: Last

    var body: some View {
        ViewThatFits(in: .vertical) {
            stages
            last.environment(\.widgetStrictFit, false)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

/// Kennung einer Stufe aus einer Reihe (`ForEach` in `ViewThatFits`). Die Kennungen müssen über
/// alle Stufen eindeutig sein, sonst bricht `ViewThatFits` zur Laufzeit ab.
private struct StageID: Hashable, Identifiable {
    let kind: String
    let count: Int
    var id: Self { self }
}

/// Kopf → Inhalt 8 pt, darunter ggf. die Herkunft (iPhone).
private struct Stage<Header: View, Content: View>: View {
    let snapshot: WidgetSnapshot?
    @ViewBuilder var header: Header
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: WidgetSpace.medium) {
            header
            content
            // Nur bei Ständen vom Mac über iCloud; sonst kein Kind, damit kein Abstand dazukommt.
            if let snapshot, snapshot.machine != nil { MachineFooter(snapshot: snapshot) }
        }
    }
}

/// Kopf der Widgets mit allen Konten: einzeilig, sonst das Detail in Zeile 2.
private struct WideHeader: View {
    let title: WidgetTitle
    let detail: HeaderDetail?
    let severity: Severity?

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HeaderLine(title: title, detail: detail, severity: severity).row
            HeaderTwoLines(title: title, detail: detail ?? HeaderDetail(), severity: severity)
        }
    }
}

/// Senkrechte Trennlinie zwischen zwei Spalten (Mitte der 16 pt).
private struct ColumnRule: View {
    var body: some View {
        Rectangle().fill(.separator).frame(width: WidgetMetric.hairline)
            .padding(.horizontal, (WidgetSpace.column - WidgetMetric.hairline) / 2)
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

    private var title: WidgetTitle {
        WidgetTitle(provider.flatMap { snapshot?.provider($0)?.name } ?? "Verbrauch")
    }

    @ViewBuilder
    private func content(_ snapshot: WidgetSnapshot) -> some View {
        let summary = snapshot.summary(provider: provider, period: period) ?? UsageSummary()
        let severity = snapshot.tightest?.window.severity
        let detail = HeaderDetail(text: period.label)
        if summary.total.isZero {
            StageLadder {
                Stage(snapshot: snapshot) {
                    HeaderLine(title: title, detail: detail, severity: severity)
                } content: { empty }
            } last: {
                Stage(snapshot: snapshot) {
                    HeaderTwoLines(title: title, detail: detail, severity: severity)
                } content: { empty }
            }
        } else {
            let figures = Figures(summary: summary, showMoney: snapshot.showMoney)
            switch size {
            case .small: small(snapshot, figures, detail, severity)
            case .medium: medium(snapshot, figures, detail, severity)
            case .large: large(snapshot, figures, detail, severity)
            case .extraLarge: extraLarge(snapshot, figures, detail, severity)
            }
        }
    }

    private var empty: some View {
        CappedText(text: Text("Keine Einträge in diesem Zeitraum.").token(.note).foregroundStyle(.secondary),
                   font: .note, lines: 3)
    }

    /// U1 Kopf einzeilig · Tokens mit Cache-Zeile · API-Wert → U2 Kopf zweizeilig → U3 ohne
    /// Cache-Zeile (Cache bleibt in mittel/groß und in der App).
    private func small(_ snapshot: WidgetSnapshot, _ figures: Figures, _ detail: HeaderDetail, _ severity: Severity?) -> some View {
        StageLadder {
            Stage(snapshot: snapshot) {
                HeaderLine(title: title, detail: detail, severity: severity)
            } content: { figures.smallStats(cache: true) }
            Stage(snapshot: snapshot) {
                HeaderTwoLines(title: title, detail: detail, severity: severity)
            } content: { figures.smallStats(cache: true) }
        } last: {
            Stage(snapshot: snapshot) {
                HeaderTwoLines(title: title, detail: detail, severity: severity)
            } content: { figures.smallStats(cache: false) }
        }
    }

    /// Links Tokens und API-Wert, rechts das Tagesdiagramm („Tokens je Tag“) bzw. bei „Heute“
    /// Input/Output/Cache.
    private func medium(_ snapshot: WidgetSnapshot, _ figures: Figures, _ detail: HeaderDetail, _ severity: Severity?) -> some View {
        StageLadder {
            Stage(snapshot: snapshot) {
                HeaderLine(title: title, detail: detail, severity: severity)
            } content: { figures.mediumColumns(cache: true, spacing: WidgetSpace.medium) }
            Stage(snapshot: snapshot) {
                HeaderLine(title: title, detail: detail, severity: severity)
            } content: { figures.mediumColumns(cache: true, spacing: WidgetSpace.tight) }
        } last: {
            Stage(snapshot: snapshot) {
                HeaderTwoLines(title: title, detail: detail, severity: severity)
            } content: { figures.mediumColumns(cache: false, spacing: WidgetSpace.tight) }
        }
    }

    /// Kopf · 8 · Tokens | API-Wert · 12 · Diagramm 44 · 12 · Modellzeilen. Erst einzeilige
    /// Modellzeilen (6 → 3 + Sammelzeile), dann zweizeilige, wenn das Detail nicht in eine
    /// Zeile passt – nie mit „…“.
    private func large(_ snapshot: WidgetSnapshot, _ figures: Figures, _ detail: HeaderDetail, _ severity: Severity?) -> some View {
        let counts = ModelRows.counts(total: figures.summary.models.count)
        return StageLadder {
            ForEach(counts.map { StageID(kind: "U1", count: $0) }) { stage in
                Stage(snapshot: snapshot) {
                    HeaderLine(title: title, detail: detail, severity: severity)
                } content: { figures.largeBody(models: stage.count, twoLineRows: false) }
            }
            ForEach(counts.map { StageID(kind: "U2", count: $0) }) { stage in
                Stage(snapshot: snapshot) {
                    HeaderLine(title: title, detail: detail, severity: severity)
                } content: { figures.largeBody(models: stage.count, twoLineRows: true) }
            }
        } last: {
            Stage(snapshot: snapshot) {
                HeaderTwoLines(title: title, detail: detail, severity: severity)
            } content: { figures.largeBody(models: counts.last ?? 0, twoLineRows: true) }
        }
    }

    /// V1: Kennzahlen nebeneinander · Diagramm 72 über die volle Breite · einzeilige
    /// Modellzeilen in zwei Spalten (12 → 4 + Sammelzeile), dann dasselbe mit Diagramm 44.
    /// V2: Diagramm 44, zweizeilige Modellzeilen.
    private func extraLarge(_ snapshot: WidgetSnapshot, _ figures: Figures, _ detail: HeaderDetail, _ severity: Severity?) -> some View {
        let counts = ModelRows.counts(total: figures.summary.models.count,
                                      maximum: ModelRows.extraLargeMaximum, minimum: ModelRows.extraLargeMinimum)
        let title = title
        return StageLadder {
            ForEach(counts.map { StageID(kind: "V1-72", count: $0) }) { stage in
                Stage(snapshot: snapshot) {
                    HeaderLine(title: title, detail: detail, severity: severity)
                } content: {
                    figures.extraLargeBody(models: stage.count, chart: WidgetMetric.wideChart, twoLineRows: false)
                }
            }
            ForEach(counts.map { StageID(kind: "V1-44", count: $0) }) { stage in
                Stage(snapshot: snapshot) {
                    HeaderLine(title: title, detail: detail, severity: severity)
                } content: {
                    figures.extraLargeBody(models: stage.count, chart: WidgetMetric.chart, twoLineRows: false)
                }
            }
            ForEach(counts.map { StageID(kind: "V2", count: $0) }) { stage in
                Stage(snapshot: snapshot) {
                    HeaderLine(title: title, detail: detail, severity: severity)
                } content: {
                    figures.extraLargeBody(models: stage.count, chart: WidgetMetric.chart, twoLineRows: true)
                }
            }
        } last: {
            Stage(snapshot: snapshot) {
                HeaderLine(title: title, detail: detail, severity: severity)
            } content: {
                figures.extraLargeBody(models: counts.last ?? 0, chart: WidgetMetric.chart, twoLineRows: true)
            }
        }
    }
}

/// Die Kennzahlen eines Zeitraums in den Formen der Größen.
@MainActor
private struct Figures {
    let summary: UsageSummary
    let showMoney: Bool

    private var tokens: String { Format.tokens(summary.total.total) }
    private var value: String { Format.money(summary.value) + (summary.hasUnpriced ? "*" : "") }
    private var cacheRead: String { Format.tokens(summary.total.cacheRead) }

    func smallStats(cache: Bool) -> some View {
        VStack(alignment: .leading, spacing: WidgetSpace.medium) {
            StatView(title: "Tokens", value: tokens, detail: cache ? "\(cacheRead) Cache-Lesen" : nil, font: .figure)
            if showMoney {
                StatView(title: "API-Vergleichswert", value: value, detail: nil, font: .figureSmall)
            }
        }
    }

    /// `spacing`: Abstand der Input/Output/Cache-Werte – 8, in knappen Kacheln 3.
    func mediumColumns(cache: Bool, spacing: CGFloat) -> some View {
        HStack(alignment: .top, spacing: WidgetSpace.column) {
            VStack(alignment: .leading, spacing: WidgetSpace.medium) {
                StatView(title: "Tokens", value: tokens, detail: cache ? "\(cacheRead) davon Cache-Lesen" : nil, font: .figure)
                if showMoney {
                    StatView(title: "API-Vergleichswert", value: value, detail: nil, font: .figure)
                }
            }
            .frame(maxWidth: .infinity, alignment: .topLeading)
            Group {
                if summary.days.count > 1 {
                    VStack(alignment: .leading, spacing: WidgetSpace.tight) {
                        Line("Tokens je Tag", .meta, color: .secondary)
                        WidgetDayChart(days: summary.days)
                            .frame(minHeight: WidgetMetric.chart, maxHeight: .infinity)
                    }
                } else {
                    VStack(alignment: .leading, spacing: spacing) {
                        StatView(title: "Input", value: Format.tokens(summary.total.input), detail: nil, font: .figureSmall)
                        StatView(title: "Output", value: Format.tokens(summary.total.output), detail: nil, font: .figureSmall)
                        StatView(title: "Cache", value: Format.tokens(summary.total.cache), detail: nil, font: .figureSmall)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
    }

    private var keyFigures: some View {
        HStack(alignment: .top, spacing: WidgetSpace.column) {
            StatView(title: "Tokens", value: tokens, detail: "\(cacheRead) davon Cache-Lesen", font: .figure)
                .frame(maxWidth: .infinity, alignment: .leading)
            if showMoney {
                StatView(title: "API-Vergleichswert", value: value, detail: "berechnet, keine Kosten", font: .figure)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    func largeBody(models count: Int, twoLineRows: Bool) -> some View {
        let models = summary.models
        return VStack(alignment: .leading, spacing: 0) {
            keyFigures
            if summary.days.count > 1 {
                WidgetDayChart(days: summary.days)
                    .frame(height: WidgetMetric.chart)
                    .padding(.top, WidgetSpace.large)
            }
            VStack(alignment: .leading, spacing: 0) {
                ModelColumn(lines: Array(models.prefix(count)), showMoney: showMoney, twoLines: twoLineRows)
                moreModels(models.count - count)
            }
            .padding(.top, WidgetSpace.large)
        }
    }

    func extraLargeBody(models count: Int, chart: CGFloat, twoLineRows: Bool) -> some View {
        let models = summary.models
        let shown = Array(models.prefix(count))
        let left = ColumnSplit.halves(shown.count)
        return VStack(alignment: .leading, spacing: 0) {
            keyFigures
            if summary.days.count > 1 {
                VStack(alignment: .leading, spacing: 4) {
                    Line("Tokens je Tag", .meta, color: .secondary)
                    WidgetDayChart(days: summary.days).frame(height: chart)
                }
                .padding(.top, WidgetSpace.large)
            }
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .top, spacing: WidgetSpace.column) {
                    ModelColumn(lines: Array(shown.prefix(left)), showMoney: showMoney, twoLines: twoLineRows)
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                    ModelColumn(lines: Array(shown.dropFirst(left)), showMoney: showMoney, twoLines: twoLineRows)
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                }
                moreModels(models.count - count)
            }
            .padding(.top, WidgetSpace.large)
        }
    }

    @ViewBuilder
    private func moreModels(_ count: Int) -> some View {
        if count > 0 {
            CappedText(text: Text(WidgetText.moreModels(count)).token(.meta).foregroundStyle(.secondary),
                       font: .meta, lines: 2)
                .padding(.top, 4)
        }
    }
}

/// Stat-Titel 10 · Kennzahl 20 bzw. 15 · Detail 10, je einzeilig.
private struct StatView: View {
    let title: String
    let value: String
    let detail: String?
    let font: WidgetFont

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Line(title, .meta, color: .secondary)
            Line(Text(value).token(font).monospacedDigit(), font)
            if let detail {
                Line(Text(detail).token(.meta).foregroundStyle(.secondary).monospacedDigit(), .meta)
            }
        }
    }
}

/// Modellzeilen untereinander, je mit Trennlinie.
private struct ModelColumn: View {
    let lines: [UsageSummary.ModelLine]
    let showMoney: Bool
    let twoLines: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(lines) { line in
                ModelRow(line: line, showMoney: showMoney, twoLines: twoLines)
                Rectangle().fill(.separator).frame(height: WidgetMetric.hairline)
            }
        }
    }
}

/// Modellzeile: einzeilig Name · Detail · Wert (4 + 14 + 4), zweizeilig mit dem Detail darunter.
private struct ModelRow: View {
    let line: UsageSummary.ModelLine
    let showMoney: Bool
    let twoLines: Bool

    private var detail: String {
        "\(Format.tokens(line.counts.input)) in · \(Format.tokens(line.counts.output)) out · \(Format.tokens(line.counts.cache)) Cache"
    }

    var body: some View {
        Group {
            if twoLines {
                VStack(alignment: .leading, spacing: 0) {
                    OneLine { head(withDetail: false) }
                    Line(Text(detail).token(.meta).foregroundStyle(.secondary).monospacedDigit(), .meta)
                }
            } else {
                OneLine { head(withDetail: true) }
            }
        }
        .padding(.vertical, 4)
    }

    private func head(withDetail: Bool) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 0) {
            Text(ModelName.display(line.model)).token(.row).frame(height: WidgetFont.row.lineHeight).fixedSize()
            if withDetail {
                Text(detail).token(.meta).foregroundStyle(.secondary).monospacedDigit().fixedSize()
                    .padding(.leading, WidgetSpace.medium)
            }
            Spacer(minLength: WidgetSpace.medium)
            if showMoney {
                Text(line.value.map(Format.money) ?? "ohne Preis").token(.row)
                    .foregroundStyle(line.value == nil ? Color.secondary : Color.primary)
                    .monospacedDigit()
                    .frame(height: WidgetFont.row.lineHeight)
                    .fixedSize()
            }
        }
        .frame(height: WidgetFont.row.lineHeight)
    }
}

/// Tagesdiagramm der Widgets: Säulenabstand 2, Radius oben 2, heute kräftig.
private struct WidgetDayChart: View {
    let days: [UsageSummary.DayTotal]

    var body: some View {
        let peak = max(days.map(\.tokens).max() ?? 0, 1)
        GeometryReader { geo in
            HStack(alignment: .bottom, spacing: 2) {
                ForEach(days) { day in
                    UnevenRoundedRectangle(topLeadingRadius: 2, topTrailingRadius: 2)
                        .fill(Color.accentColor.opacity(day.id == days.last?.id ? 1 : 0.55))
                        .frame(maxWidth: .infinity)
                        .frame(height: max(geo.size.height * CGFloat(day.tokens) / CGFloat(peak), day.tokens > 0 ? 2 : 0))
                }
            }
            .frame(maxHeight: .infinity, alignment: .bottom)
        }
    }
}

// MARK: - Limits

/// Widget „Limits“: klein und mittel ein Anbieter (bzw. ein Konto) mit Pace-Marke, groß und
/// extragroß alle.
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
            switch size {
            case .large: LimitsLarge(snapshot: snapshot, now: now)
            case .extraLarge: LimitsExtraLarge(snapshot: snapshot, now: now)
            case .medium, .small:
                if let shown = Self.resolve(snapshot, provider: provider) {
                    LimitsSingle(snapshot: snapshot, provider: shown, medium: size == .medium, now: now)
                } else {
                    LimitsSingle.missing(snapshot: snapshot, name: provider.map { WidgetTitle($0) })
                }
            }
        } else {
            WidgetPlaceholder()
        }
    }

    /// Welcher Anbieter gezeigt wird: der gewählte – mit mehreren Konten (PR #2) dessen
    /// Standardkonto, das die ID des Anbieters behält (Variante B, Sven 27.11.2026) – oder bei
    /// „Knappstes Limit“ der mit dem knappsten Limit, sonst der erste mit Stand.
    public static func resolve(_ snapshot: WidgetSnapshot, provider: String?) -> WidgetSnapshot.Provider? {
        if let provider { return snapshot.provider(provider) }
        return snapshot.tightest?.provider ?? snapshot.providers.first { $0.snapshot != nil } ?? snapshot.providers.first
    }
}

/// Klein und mittel: ein Konto. Klein zeigt die zwei knappsten Limits, mittel bis zu vier.
private struct LimitsSingle: View {
    let snapshot: WidgetSnapshot
    let provider: WidgetSnapshot.Provider
    let medium: Bool
    let now: Date

    /// Gewählter Anbieter ist nicht (mehr) installiert.
    static func missing(snapshot: WidgetSnapshot, name: WidgetTitle?) -> some View {
        let title = name ?? WidgetTitle("Limits")
        return StageLadder {
            Stage(snapshot: snapshot) {
                HeaderLine(title: title, detail: nil, severity: nil)
            } content: { FailureNote(message: noDataMessage) }
        } last: {
            Stage(snapshot: snapshot) {
                HeaderWrapped(title: .wrapping(titleText(title, .title), words: nameWords(title.full)), detail: nil, severity: nil)
            } content: { FailureNote(message: noDataMessage) }
        }
    }

    var body: some View {
        let title = WidgetTitle(provider.name)
        let severity = provider.snapshot?.tightestWindow?.severity
        let detail = HeaderDetail.plan(provider.snapshot?.account?.plan, paused: provider.isRateLimited)
        if let windows = provider.snapshot?.windows, !windows.isEmpty {
            ladder(windows: windows, title: title, detail: detail, severity: severity)
        } else {
            failure(title: title, detail: detail)
        }
    }

    /// Stufen klein S1–S8, mittel M1–M8 (Konzept „Widgets einheitlich“, 4.3). S5 entfällt:
    /// Kontonamen haben höchstens 24 Zeichen, mehr als zwei Titelzeilen braucht es nie.
    @ViewBuilder
    private func ladder(windows all: [LimitWindow], title: WidgetTitle, detail: HeaderDetail, severity: Severity?) -> some View {
        let pick = LimitPick.tightest(all, count: medium ? LimitPick.medium : LimitPick.small)
        let two = LimitPick.tightest(all, count: LimitPick.compact)
        let required = detail.isRequired
        // Mittel: Fallen Limits weg (mehr als vier), sagt der Kopf es. Klein zeigt bewusst nur
        // die zwei knappsten, ohne Hinweis – die übrigen stehen im mittleren Widget und in der App.
        let fullDetail = medium && pick.hidden > 0 ? detail.with(prefix: WidgetText.hiddenLimitsInApp(pick.hidden)) : detail
        let words = nameWords(title.account ?? title.full)
        StageLadder {
            // S1/M1: Kopf einzeilig mit Detail, alle (bzw. die knappsten) Meter-Blöcke.
            Stage(snapshot: snapshot) {
                HeaderLine(title: title, detail: fullDetail, severity: severity)
            } content: { blocks(pick.shown) }
            // S2/M2: Kopf ohne Detail (nicht bei Pflichtdetail).
            if !required {
                Stage(snapshot: snapshot) {
                    HeaderLine(title: title, detail: nil, severity: severity)
                } content: { blocks(pick.shown) }
            }
            // M3: zwei knappste Limits, „+N Limits in der App“.
            if medium && all.count > LimitPick.compact {
                let hidden = WidgetText.hiddenLimitsInApp(all.count - LimitPick.compact)
                Stage(snapshot: snapshot) {
                    HeaderLine(title: title, detail: required ? detail.with(prefix: hidden) : HeaderDetail(text: hidden),
                               severity: severity)
                } content: { blocks(two.shown) }
            }
            // S3: Kopf zweizeilig · Meter-Block + Kurzmeter.
            if !detail.isEmpty {
                Stage(snapshot: snapshot) {
                    HeaderTwoLines(title: title, detail: detail, severity: severity)
                } content: { MeterCompact(windows: two.shown, now: now) }
            }
            // S4: Titel zweizeilig – am „·“, ohne Kontoteil am Wortende – mit Detail.
            Stage(snapshot: snapshot) {
                HeaderWrapped(title: wrappedTitle(title), detail: detail, severity: severity)
            } content: { MeterCompact(windows: two.shown, now: now) }
            if title.account != nil {
                // S6: Kontoname als Titel, „Claude · Tarif“ in der Detailzeile.
                Stage(snapshot: snapshot) {
                    HeaderWrapped(title: .wrapping(lastTitle(title), words: words), detail: lastDetail(title, detail),
                                  severity: severity)
                } content: { MeterCompact(windows: two.shown, now: now) }
            }
            // S7: wie S6, der Zustandspunkt steht in der Detailzeile, der Titel wird breiter.
            Stage(snapshot: snapshot) {
                HeaderWrapped(title: .wrapping(lastTitle(title), words: words), detail: lastDetail(title, detail),
                              severity: severity, dotInDetail: true)
            } content: { MeterCompact(windows: two.shown, now: now) }
        } last: {
            // S8: wie S7, hier darf ein langes Wort zeichenweise brechen.
            Stage(snapshot: snapshot) {
                HeaderWrapped(title: .wrapping(lastTitle(title), words: words), detail: lastDetail(title, detail),
                              severity: severity, dotInDetail: true)
            } content: { MeterCompact(windows: two.shown, now: now) }
        }
    }

    @ViewBuilder
    private func blocks(_ windows: [LimitWindow]) -> some View {
        if medium {
            MeterGrid(windows: windows, now: now)
        } else {
            MeterColumn(windows: windows, now: now)
        }
    }

    private func wrappedTitle(_ title: WidgetTitle) -> HeaderWrapped.Title {
        title.account == nil ? .wrapping(titleText(title, .title), words: nameWords(title.full)) : .split(title)
    }

    private func lastTitle(_ title: WidgetTitle) -> Text {
        title.account.map { Text($0).token(.title) } ?? titleText(title, .title)
    }

    private func lastDetail(_ title: WidgetTitle, _ detail: HeaderDetail) -> HeaderDetail {
        title.account == nil ? detail : detail.with(prefix: title.provider)
    }

    /// F1: Kopf und Hinweis („Anmeldung abgelaufen …“) statt Metern.
    private func failure(title: WidgetTitle, detail: HeaderDetail) -> some View {
        let message = provider.message ?? noDataMessage
        let words = nameWords(title.account ?? title.full)
        return StageLadder {
            Stage(snapshot: snapshot) {
                HeaderLine(title: title, detail: detail, severity: nil)
            } content: { FailureNote(message: message) }
            Stage(snapshot: snapshot) {
                HeaderLine(title: title, detail: nil, severity: nil)
            } content: { FailureNote(message: message) }
            Stage(snapshot: snapshot) {
                HeaderWrapped(title: wrappedTitle(title), detail: nil, severity: nil)
            } content: { FailureNote(message: message) }
        } last: {
            Stage(snapshot: snapshot) {
                HeaderWrapped(title: .wrapping(lastTitle(title), words: words), detail: lastDetail(title, HeaderDetail()),
                              severity: nil, dotInDetail: true)
            } content: { FailureNote(message: message) }
        }
    }
}

/// Gemeinsames der Widgets mit allen Konten: Kopf, Sortierung, Abschnitte.
@MainActor
private struct AllAccounts {
    let snapshot: WidgetSnapshot
    let now: Date

    var providers: [WidgetSnapshot.Provider] { snapshot.providers }
    var ordered: [WidgetSnapshot.Provider] { LimitsTable.ordered(providers) }
    var accounts: Bool { WidgetText.hasAccounts(providers) }
    var title: WidgetTitle { WidgetTitle("Limits") }
    /// Bei nur einem Anbieter ohne Zählung („Limits“), sonst „4 Anbieter“ bzw. „8 Konten“.
    var detail: HeaderDetail { HeaderDetail(text: providers.count < 2 ? nil : WidgetText.providerCount(providers)) }
    var severity: Severity? { snapshot.tightest?.window.severity }

    func stage<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        Stage(snapshot: snapshot) {
            WideHeader(title: title, detail: detail, severity: severity)
        } content: { content() }
    }

    var empty: some View {
        Stage(snapshot: snapshot) {
            HeaderLine(title: title, detail: nil, severity: nil)
        } content: { FailureNote(message: noDataMessage) }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    func sections(_ providers: [WidgetSnapshot.Provider], limit: Int, columns: Int = 2) -> some View {
        // Bei genau einem Anbieter steht sein Zustand schon im Widgetkopf – kein zweiter Punkt.
        let dots = self.providers.count > 1
        return VStack(alignment: .leading, spacing: WidgetSpace.large) {
            ForEach(providers) { provider in
                AccountSection(provider: provider, limit: limit, columns: columns, showDot: dots, now: now)
            }
        }
    }

    /// Abschnitte in zwei Spalten, nach geschätzter Höhe ausgeglichen (X2/X3).
    func sectionColumns(limit: Int) -> some View {
        let heights = providers.map { AccountSection.estimatedHeight($0, limit: limit, now: now) }
        let left = ColumnSplit.balanced(heights, spacing: Double(WidgetSpace.large))
        return HStack(alignment: .top, spacing: 0) {
            sections(Array(providers.prefix(left)), limit: limit)
                .frame(maxWidth: .infinity, alignment: .topLeading)
            ColumnRule()
            sections(Array(providers.dropFirst(left)), limit: limit)
                .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .fixedSize(horizontal: false, vertical: true)
    }
}

/// Groß: alle Konten. Erst Abschnitte mit Metern (L1 alle Limits, L2 die zwei knappsten), dann
/// eine Tabelle mit einer Zeile je Konto (L3), mit Sammelzeile (L4) und zuletzt ohne
/// Limitnamen-Spalte (L5).
private struct LimitsLarge: View {
    let snapshot: WidgetSnapshot
    let now: Date

    var body: some View {
        let all = AllAccounts(snapshot: snapshot, now: now)
        let ordered = all.ordered
        let accounts = all.accounts
        let counts = LimitsTable.rowCounts(total: ordered.count)
        if all.providers.isEmpty {
            all.empty
        } else {
            StageLadder {
                all.stage { all.sections(all.providers, limit: LimitPick.section) }
                all.stage { all.sections(all.providers, limit: LimitPick.compact) }
                all.stage { table(ordered, shown: ordered.count, limitColumn: true, accounts) }
                ForEach(counts.map { StageID(kind: "L4", count: $0) }) { stage in
                    all.stage { table(ordered, shown: stage.count, limitColumn: true, accounts) }
                }
                ForEach(([ordered.count] + counts).map { StageID(kind: "L5", count: $0) }) { stage in
                    all.stage { table(ordered, shown: stage.count, limitColumn: false, accounts) }
                }
            } last: {
                all.stage { table(ordered, shown: min(ordered.count, LimitsTable.minimumRows), limitColumn: false, accounts) }
            }
        }
    }

    private func table(_ ordered: [WidgetSnapshot.Provider], shown: Int, limitColumn: Bool, _ accounts: Bool) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            AccountTable(rows: Array(ordered.prefix(shown)), limitColumn: limitColumn, accounts: accounts, now: now)
            if shown < ordered.count {
                MoreAccounts(rest: Array(ordered.dropFirst(shown)), accounts: accounts)
            }
        }
    }
}

/// Extragroß: zwei Spalten so breit wie ein großes Widget. X1 Abschnitte über die volle Breite
/// mit vier Metern je Zeile (bis zwei Konten), X2/X3 Abschnitte zweispaltig, X4 eine Tabelle mit
/// zwei Limits je Konto, X5 zwei Tabellen nebeneinander, zuletzt mit Sammelzeile.
private struct LimitsExtraLarge: View {
    let snapshot: WidgetSnapshot
    let now: Date

    var body: some View {
        let all = AllAccounts(snapshot: snapshot, now: now)
        let ordered = all.ordered
        let accounts = all.accounts
        let counts = LimitsTable.rowCounts(total: ordered.count)
        if all.providers.isEmpty {
            all.empty
        } else {
            StageLadder {
                if all.providers.count <= 2 {
                    all.stage { all.sections(all.providers, limit: LimitPick.section, columns: 4) }
                }
                all.stage { all.sectionColumns(limit: LimitPick.section) }
                all.stage { all.sectionColumns(limit: LimitPick.compact) }
                all.stage {
                    AccountTable(rows: ordered, limitColumn: true, accounts: accounts, secondLimit: true, now: now)
                }
                ForEach(([ordered.count] + counts).map { StageID(kind: "X5", count: $0) }) { stage in
                    all.stage { twoTables(ordered, shown: stage.count, limitColumn: true, accounts) }
                }
                ForEach(([ordered.count] + counts).map { StageID(kind: "X5-kurz", count: $0) }) { stage in
                    all.stage { twoTables(ordered, shown: stage.count, limitColumn: false, accounts) }
                }
            } last: {
                all.stage {
                    twoTables(ordered, shown: min(ordered.count, LimitsTable.minimumRows), limitColumn: false, accounts)
                }
            }
        }
    }

    /// Spaltenweise gefüllt: links die ersten ⌈k/2⌉, rechts der Rest; Sammelzeile über die volle Breite.
    private func twoTables(_ ordered: [WidgetSnapshot.Provider], shown: Int, limitColumn: Bool, _ accounts: Bool) -> some View {
        let rows = Array(ordered.prefix(shown))
        let left = ColumnSplit.halves(rows.count)
        return VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: WidgetSpace.column) {
                AccountTable(rows: Array(rows.prefix(left)), limitColumn: limitColumn, accounts: accounts, now: now)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                AccountTable(rows: Array(rows.dropFirst(left)), limitColumn: limitColumn, accounts: accounts, now: now)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
            }
            if shown < ordered.count {
                MoreAccounts(rest: Array(ordered.dropFirst(shown)), accounts: accounts)
                    .padding(.top, 4)
            }
        }
    }
}

/// Konto-Abschnitt: Kopfzeile 14 (Name · Tarif · „+1 Limit“ · Punkt, bei genau einem Anbieter
/// ohne Punkt) · 6 · Meter in zwei
/// (extragroß X1: vier) Spalten. Fehlerkonto: Kopfzeile + Hinweis mit Warnsymbol, höchstens
/// zwei Zeilen.
private struct AccountSection: View {
    let provider: WidgetSnapshot.Provider
    let limit: Int
    var columns = 2
    var showDot = true
    let now: Date

    var body: some View {
        let windows = provider.snapshot?.windows ?? []
        let pick = LimitPick.tightest(windows, count: limit)
        VStack(alignment: .leading, spacing: WidgetSpace.small) {
            OneLine { head(hidden: pick.hidden) }
            if windows.isEmpty {
                FailureNote(message: provider.message ?? noDataMessage, font: .meta, lines: 2)
            } else {
                MeterGrid(windows: pick.shown, now: now, showScope: true, columns: columns)
            }
        }
    }

    /// Geschätzte Höhe nach der Maßtabelle – nur, um die Abschnitte auf zwei Spalten zu verteilen.
    static func estimatedHeight(_ provider: WidgetSnapshot.Provider, limit: Int, now: Date) -> Double {
        let head = Double(WidgetFont.row.lineHeight + WidgetSpace.small)
        let windows = LimitPick.tightest(provider.snapshot?.windows ?? [], count: limit).shown
        guard !windows.isEmpty else { return head + 2 * Double(WidgetFont.meta.lineHeight) }
        func block(_ window: LimitWindow) -> Double {
            let elapsed = window.elapsedFraction(now: now)
            var height = 14.0 + 3 + 6
            if window.resetsAt != nil || elapsed != nil { height += 3 }
            if window.resetsAt != nil { height += 12 }
            if elapsed != nil && window.windowLength != nil { height += 12 }
            return height
        }
        let rows = stride(from: 0, to: windows.count, by: 2).map {
            windows[$0..<min($0 + 2, windows.count)].map(block).max() ?? 0
        }
        return head + rows.reduce(0, +) + Double(WidgetSpace.medium) * Double(rows.count - 1)
    }

    private func head(hidden: Int) -> some View {
        HStack(spacing: 0) {
            titleText(WidgetTitle(provider.name), .row).frame(height: WidgetFont.row.lineHeight).fixedSize()
            let detail = HeaderDetail.plan(provider.snapshot?.account?.plan, paused: provider.isRateLimited)
            if !detail.isEmpty {
                detail.textView.frame(height: WidgetFont.meta.lineHeight).fixedSize()
                    .padding(.leading, WidgetSpace.small)
            }
            Spacer(minLength: WidgetSpace.small)
            if hidden > 0 {
                Text(WidgetText.hiddenLimits(hidden)).token(.meta).foregroundStyle(.secondary)
                    .frame(height: WidgetFont.meta.lineHeight).fixedSize()
                    .padding(.trailing, WidgetSpace.small)
            }
            if showDot && !provider.isFailing {
                StatusDot(severity: provider.snapshot?.tightestWindow?.severity)
            }
        }
        .frame(height: WidgetFont.row.lineHeight)
    }
}

/// Tabelle: Kopf „Konto“ | „Knappstes Limit“ (über Limitname, Balken und Prozent) · 4 · Zeilen
/// mind. 20 pt mit Trennlinie, schon sortiert (`LimitsTable.ordered`). Extragroß X4 hat eine
/// zweite Gruppe „Zweites Limit“, 16 pt neben der ersten.
private struct AccountTable: View {
    let rows: [WidgetSnapshot.Provider]
    let limitColumn: Bool
    let accounts: Bool
    var secondLimit = false
    let now: Date

    private var group: CGFloat {
        (limitColumn ? WidgetMetric.limitColumn + WidgetSpace.medium : 0)
            + WidgetMetric.tableBar + WidgetSpace.medium + WidgetMetric.percentColumn
    }

    private var span: CGFloat {
        secondLimit ? group * 2 + WidgetSpace.column : group
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: WidgetSpace.medium) {
                Line(accounts ? "Konto" : "Anbieter", .meta, color: .secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                HStack(spacing: WidgetSpace.column) {
                    Line("Knappstes Limit", .meta, color: .secondary)
                        .frame(width: group, alignment: .leading)
                    if secondLimit {
                        Line("Zweites Limit", .meta, color: .secondary)
                            .frame(width: group, alignment: .leading)
                    }
                }
            }
            .padding(.bottom, 4)
            ForEach(rows) { provider in
                row(provider)
                Rectangle().fill(.separator).frame(height: WidgetMetric.hairline)
            }
        }
    }

    private func row(_ provider: WidgetSnapshot.Provider) -> some View {
        let windows = LimitPick.descending(provider.snapshot?.windows ?? [], count: secondLimit ? 2 : 1)
        return HStack(alignment: .center, spacing: WidgetSpace.medium) {
            CappedText(text: titleText(WidgetTitle(provider.name), .row), font: .row, lines: 2,
                       words: nameWords(provider.name))
                .frame(maxWidth: .infinity, alignment: .leading)
            if windows.isEmpty {
                // Fehlerkonto: Hinweis über den Limitspalten, wenn er passt, sonst kurz.
                ViewThatFits(in: .horizontal) {
                    failure(provider.message ?? "kein Stand")
                    failure("kein Stand")
                }
                .frame(width: span, alignment: .leading)
            } else {
                HStack(spacing: WidgetSpace.column) {
                    cells(windows[0], paused: provider.isRateLimited)
                    if secondLimit {
                        if windows.count > 1 {
                            cells(windows[1], paused: provider.isRateLimited)
                        } else {
                            Color.clear.frame(width: group, height: 0)
                        }
                    }
                }
            }
        }
        .padding(.vertical, WidgetSpace.tight)
        .frame(minHeight: WidgetMetric.tableRow)
    }

    /// Limitname (70) · Balken 4 (72) · Prozent (34); bei pausierter Abfrage das Pause-Symbol
    /// vor dem Limitnamen.
    private func cells(_ window: LimitWindow, paused: Bool) -> some View {
        HStack(spacing: WidgetSpace.medium) {
            if limitColumn {
                let pause = paused ? Text(Image(systemName: "pause.fill")).font(.system(size: 9)) + Text(" ") : Text("")
                ViewThatFits(in: .horizontal) {
                    Line((pause + Text(window.name)).token(.meta).foregroundStyle(.secondary), .meta)
                    Line(pause.foregroundStyle(.secondary), .meta)
                }
                .frame(width: WidgetMetric.limitColumn, alignment: .leading)
            }
            MeterBar(percent: window.percent, elapsed: window.elapsedFraction(now: now),
                     color: window.severity.color, markHeight: WidgetMetric.shortMark)
                .frame(width: WidgetMetric.tableBar, height: WidgetMetric.shortBar)
            PercentLabel(window: window)
                .frame(width: WidgetMetric.percentColumn, alignment: .trailing)
        }
    }

    private func failure(_ text: String) -> some View {
        (warningSymbol() + Text(" ") + Text(text).token(.meta).foregroundStyle(.secondary))
            .frame(height: WidgetFont.meta.lineHeight)
            .fixedSize()
    }
}

/// Sammelzeile „+7 weitere Konten · höchstens 26 %“.
private struct MoreAccounts: View {
    let rest: [WidgetSnapshot.Provider]
    let accounts: Bool

    var body: some View {
        CappedText(text: Text(WidgetText.moreAccounts(rest, accounts: accounts))
            .token(.meta).foregroundStyle(.secondary).monospacedDigit(), font: .meta, lines: 2)
            .padding(.vertical, WidgetSpace.tight)
            .frame(minHeight: WidgetMetric.tableRow, alignment: .leading)
    }
}
