import SwiftUI

// Bausteine der Widgets nach dem Entwurf „Widgets einheitlich“ (SPEC §7 „Widgets“): fünf
// Schriftgrade, feste Abstandsreihe, nichts schrumpft, nichts wird mit „…“ gekürzt. Was nicht
// passt, lässt die Stufe scheitern, und `ViewThatFits` nimmt die nächste.

// MARK: - Maße

/// Schriftgrade der Widgets (SF Pro). Einzeilige Texte bekommen einen festen Rahmen in
/// Zeilenhöhe – SF Pro setzt 10 pt natürlich auf 13,2 und 15 pt auf 19 pt, ohne den Rahmen
/// springen die Stufen zu früh.
enum WidgetFont {
    /// 13/16 semibold – Widget-Titel, Platzhaltertitel.
    case title
    /// 20/24 bold – Kennzahlen Verbrauch.
    case figure
    /// 15/18 semibold – API-Wert klein, Input/Output/Cache.
    case figureSmall
    /// 11/14 semibold – Meter-Name, Prozent, Abschnittsname, Kontozeile, Modellzeile.
    case row
    /// 11/14 regular – Fehlerhinweis, „Keine Einträge …“, Platzhaltertext.
    case note
    /// 10/12 regular – Detail, Reset, Pace, Zusatz, Stat-Titel, Spaltenköpfe, Sammelzeilen.
    case meta

    var size: CGFloat {
        switch self {
        case .title: 13
        case .figure: 20
        case .figureSmall: 15
        case .row, .note: 11
        case .meta: 10
        }
    }

    var lineHeight: CGFloat {
        switch self {
        case .title: 16
        case .figure: 24
        case .figureSmall: 18
        case .row, .note: 14
        case .meta: 12
        }
    }

    var weight: Font.Weight {
        switch self {
        case .title, .figureSmall, .row: .semibold
        case .figure: .bold
        case .note, .meta: .regular
        }
    }

    func font(_ weight: Font.Weight? = nil) -> Font {
        .system(size: size, weight: weight ?? self.weight)
    }
}

/// Abstandsreihe 3 · 6 · 8 · 12 · 16 pt.
enum WidgetSpace {
    /// Name → Balken → Reset im Meter-Block.
    static let tight: CGFloat = 3
    /// Icon → Titel → Detail, Abschnittskopf → Meter.
    static let small: CGFloat = 6
    /// Kopf → Inhalt, Meter → Meter.
    static let medium: CGFloat = 8
    /// Abschnitt → Abschnitt, Gruppen im großen Verbrauch.
    static let large: CGFloat = 12
    /// Spaltenabstand.
    static let column: CGFloat = 16
}

/// Feste Maße aus der Maßtabelle.
enum WidgetMetric {
    static let robot: CGFloat = 14
    static let placeholderRobot: CGFloat = 24
    static let dot: CGFloat = 6
    static let bar: CGFloat = 6
    static let shortBar: CGFloat = 4
    static let mark: CGFloat = 10
    static let shortMark: CGFloat = 8
    /// Prozentspalte, rechtsbündig – Balken einer Reihe sind gleich lang. 38 statt 34 pt:
    /// „100 %“ bräche sonst um.
    static let percentColumn: CGFloat = 38
    /// Limitname in der Tabelle: „Code-Review“ braucht 65, „Claude & GPT“ 69 pt.
    static let limitColumn: CGFloat = 70
    static let tableBar: CGFloat = 72
    static let tableRow: CGFloat = 20
    static let hairline: CGFloat = 0.5
    static let chart: CGFloat = 44
    /// Tagesdiagramm im extragroßen Verbrauchs-Widget (Rückfall 44).
    static let wideChart: CGFloat = 72
    /// Einzug der zweiten Kopfzeile auf den Titel: Roboter 14 + 6.
    static let headerIndent: CGFloat = 20
}

// MARK: - Passt oder scheitert

/// Höhe, mit der ein Baustein „passt nicht“ meldet. `ViewThatFits(in: .vertical)` verwirft dann
/// die ganze Stufe, statt dass SwiftUI kürzt.
enum WidgetFit {
    static let overflow: CGFloat = 100_000
}

private struct StrictFitKey: EnvironmentKey {
    static let defaultValue = true
}

extension EnvironmentValues {
    /// Aus nur in der letzten Rückfallstufe: Passt selbst die nicht (etwa ein sehr langer Name
    /// in einer sehr kleinen Kachel), wird lieber am Rand abgeschnitten als gar nichts gezeigt.
    var widgetStrictFit: Bool {
        get { self[StrictFitKey.self] }
        set { self[StrictFitKey.self] = newValue }
    }
}

/// Einzeiliger Inhalt. Passt er nicht in die Breite, meldet er eine riesige Höhe – die Stufe
/// scheitert, und die Stufenleiter nimmt die nächste.
struct OneLine<Content: View>: View {
    @Environment(\.widgetStrictFit) private var strict
    @ViewBuilder var content: Content

    var body: some View {
        if strict {
            ViewThatFits(in: .horizontal) {
                content
                Color.clear.frame(width: 0, height: WidgetFit.overflow)
            }
        } else {
            content
        }
    }
}

/// Mehrzeiliger Text mit Höchsthöhe (z. B. Titel höchstens zwei Zeilen): Braucht er mehr,
/// scheitert die Stufe, statt dass eine dritte Zeile oder „…“ entsteht. Die weiteren Kinder
/// sind die einzelnen Wörter (unsichtbar): Ist eines breiter als die Zeile, bräche SwiftUI es
/// mitten im Wort – auch dann scheitert die Stufe (Regel 9; nur die letzte Stufe darf das).
struct LineCap: Layout {
    var maxHeight: CGFloat
    var strict: Bool
    var wordSlack: CGFloat = 2

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard let text = subviews.first else { return .zero }
        let size = text.sizeThatFits(ProposedViewSize(width: proposal.width, height: nil))
        guard strict else { return size }
        let overflow = CGSize(width: size.width, height: WidgetFit.overflow)
        if size.height > maxHeight + 0.5 { return overflow }
        // 2 pt Spielraum: Ein Wort, das rechnerisch knapp passt, bricht SwiftUI sonst doch noch
        // vor dem letzten Buchstaben um („Verwaltungsgesellschaf / t“ in 128 pt).
        if let width = proposal.width, width.isFinite,
           subviews.dropFirst().contains(where: { $0.sizeThatFits(.unspecified).width > width - wordSlack }) {
            return overflow
        }
        return size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        subviews.first?.place(at: bounds.origin, anchor: .topLeading,
                              proposal: ProposedViewSize(width: bounds.width, height: nil))
        for word in subviews.dropFirst() {
            word.place(at: bounds.origin, anchor: .topLeading, proposal: .zero)
        }
    }
}

/// Text, der am Wortende umbrechen darf, aber höchstens `lines` Zeilen hat. `words` sind die
/// Wörter, die nicht mitten im Wort brechen dürfen (Namen), je im Gewicht, in dem sie stehen.
struct CappedText: View {
    @Environment(\.widgetStrictFit) private var strict
    let text: Text
    let font: WidgetFont
    let lines: Int
    var words: [Word] = []

    var body: some View {
        // Halbe Zeile Spielraum: SF Pro misst je Zeile etwas mehr als die Tabellenhöhe.
        LineCap(maxHeight: CGFloat(lines) * font.lineHeight + font.lineHeight / 2, strict: strict) {
            text.fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            ForEach(Array(words.enumerated()), id: \.offset) { _, word in
                Text(word.text).font(font.font(word.weight)).fixedSize().hidden()
            }
        }
    }
}

/// Ein Wort, das nicht mitten im Wort brechen darf, mit dem Gewicht, in dem es gesetzt ist.
struct Word: Hashable {
    let text: String
    let weight: Font.Weight
}

/// Wörter eines Namens, alle im selben Gewicht (z. B. Kontoname als Titel, semibold).
func nameWords(_ name: String, weight: Font.Weight = .semibold) -> [Word] {
    name.split(whereSeparator: \.isWhitespace).map(String.init).filter { $0 != "·" }
        .map { Word(text: $0, weight: weight) }
}

/// Wörter eines Titels wie `titleText`: Anbieter semibold, Kontoteil regular.
func titleWords(_ title: WidgetTitle) -> [Word] {
    nameWords(title.provider) + (title.account.map { nameWords($0, weight: .regular) } ?? [])
}

extension Text {
    func token(_ font: WidgetFont, weight: Font.Weight? = nil) -> Text {
        self.font(font.font(weight))
    }
}

/// Einzeiliger Text: in den strengen Stufen fester Rahmen in Zeilenhöhe und `fixedSize`
/// (passt er nicht, scheitert die Stufe über `OneLine`). In der letzten Stufe bricht er statt
/// dessen um, damit nichts am Rand abgeschnitten wird.
private struct LineBox: ViewModifier {
    @Environment(\.widgetStrictFit) private var strict
    let font: WidgetFont

    func body(content: Content) -> some View {
        if strict {
            content.frame(height: font.lineHeight).fixedSize()
        } else {
            content.fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// Feste Zeilenhöhe einer Reihe; in der letzten Stufe nur als Mindesthöhe, damit umgebrochene
/// Texte Platz haben.
private struct RowBox: ViewModifier {
    @Environment(\.widgetStrictFit) private var strict
    let height: CGFloat

    func body(content: Content) -> some View {
        if strict {
            content.frame(height: height)
        } else {
            content.frame(minHeight: height)
        }
    }
}

extension View {
    func lineBox(_ font: WidgetFont) -> some View {
        modifier(LineBox(font: font))
    }

    func rowBox(_ height: CGFloat) -> some View {
        modifier(RowBox(height: height))
    }
}

/// Einzeiliger Text in Tabellenhöhe, nie gekürzt.
struct Line: View {
    let text: Text
    let font: WidgetFont

    init(_ text: Text, _ font: WidgetFont) {
        self.text = text
        self.font = font
    }

    init(_ string: String, _ font: WidgetFont, weight: Font.Weight? = nil, color: Color? = nil) {
        var text = Text(string).token(font, weight: weight)
        if let color { text = text.foregroundStyle(color) }
        self.text = text
        self.font = font
    }

    var body: some View {
        OneLine {
            text.lineBox(font)
        }
    }
}

/// „Claude · Privat“: Anbieter im Gewicht des Tokens, Kontoteil regular.
func titleText(_ title: WidgetTitle, _ font: WidgetFont) -> Text {
    guard let account = title.account else { return Text(title.provider).token(font) }
    return Text(title.provider).token(font) + Text(WidgetTitle.separator + account).token(font, weight: .regular)
}

// MARK: - Kleinteile

/// Zustandspunkt 6 pt.
struct StatusDot: View {
    let severity: Severity?

    var body: some View {
        // Ohne Stand (Fehlerkonto) kein Punkt, der Platz bleibt.
        Circle()
            .fill(severity?.color ?? .clear)
            .frame(width: WidgetMetric.dot, height: WidgetMetric.dot)
    }
}

/// Warnsymbol 10 pt in Warnfarbe vor Fehlerhinweisen.
func warningSymbol() -> Text {
    Text(Image(systemName: "exclamationmark.triangle.fill"))
        .font(.system(size: 10))
        .foregroundStyle(Severity.warn.color)
}

/// Detail im Kopf: Tarif, Zeitraum, „Abfrage pausiert“ (mit Pause-Symbol) oder bei Kontoname
/// als Titel „Claude · Max 5×“.
struct HeaderDetail: Equatable {
    var prefix: String?
    var text: String?
    var paused = false

    /// Pflichtdetail, das in keiner Stufe wegfallen darf – etwa „knappstes Konto“ beim
    /// eigenen Eintrag „Claude – knappstes Konto“ (kommt mit PR #2).
    var required = false

    /// Pflichtdetail: „Abfrage pausiert“ oder ein als Pflicht markiertes Detail.
    var isRequired: Bool { paused || required }
    var isEmpty: Bool { prefix == nil && text == nil && !paused }

    static func plan(_ plan: String?, paused: Bool) -> HeaderDetail {
        HeaderDetail(prefix: nil, text: paused ? nil : plan, paused: paused)
    }

    func with(prefix: String) -> HeaderDetail {
        var copy = self
        copy.prefix = prefix
        return copy
    }

    var textView: Text {
        var parts: [Text] = []
        if let prefix { parts.append(Text(prefix)) }
        if paused {
            parts.append(Text(Image(systemName: "pause.fill")).font(.system(size: 9)) + Text(" Abfrage pausiert"))
        } else if let text {
            parts.append(Text(text))
        }
        guard var result = parts.first else { return Text("") }
        for part in parts.dropFirst() { result = result + Text(WidgetTitle.separator) + part }
        return result.token(.meta).foregroundStyle(.secondary)
    }
}

/// „work · vor 12 Min.“ – nur für Stände, die über iCloud von einem Mac kamen.
struct MachineFooter: View {
    let snapshot: WidgetSnapshot

    var body: some View {
        if let machine = snapshot.machine {
            Line(Text(machine) + Text(" · vor ") + Text(snapshot.writtenAt, style: .relative), .meta)
                .foregroundStyle(.secondary)
        }
    }
}

// MARK: - Kopf

/// Kopf einzeilig: Roboter 14 · 6 · Titel · 6 · Detail · mind. 6 · Punkt. Höhe 16.
/// `HStack(spacing: 0)` mit expliziten Abständen, sonst werden aus 6 pt 18 pt.
struct HeaderLine: View {
    let title: WidgetTitle
    let detail: HeaderDetail?
    let severity: Severity?

    var body: some View {
        OneLine { row }
    }

    /// Ohne Scheitern – für `ViewThatFits(in: .horizontal)` mit eigener Rückfallstufe.
    var row: some View {
        HStack(spacing: 0) {
            RobotIcon(size: WidgetMetric.robot)
            titleText(title, .title).lineBox(.title)
                .padding(.leading, WidgetSpace.small)
            if let detail, !detail.isEmpty {
                detail.textView.monospacedDigit().lineBox(.meta)
                    .padding(.leading, WidgetSpace.small)
            }
            Spacer(minLength: WidgetSpace.small)
            StatusDot(severity: severity)
        }
        .rowBox(16)
    }
}

/// Kopf zweizeilig: Titelzeile, darunter das Detail auf den Titel eingerückt. 16 + 2 + 12.
struct HeaderTwoLines: View {
    let title: WidgetTitle
    let detail: HeaderDetail
    let severity: Severity?

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HeaderLine(title: title, detail: nil, severity: severity)
            OneLine {
                detail.textView.monospacedDigit().lineBox(.meta)
            }
            .padding(.leading, WidgetMetric.headerIndent)
        }
    }
}

/// Titel zweizeilig. Mit Kontoteil bricht er am „·“: Zeile 1 „Claude ·“, Zeile 2 der Kontoname,
/// der zusammenbleibt. Ohne Kontoteil (oder bei Kontoname als Titel, Stufe S6) darf der Titel
/// frei umbrechen, aber höchstens zweizeilig. Das Detail steht darunter.
struct HeaderWrapped: View {
    enum Title {
        /// „Claude ·“ / „Kunde A“
        case split(WidgetTitle)
        /// Umbruch am Wortende, höchstens zwei Zeilen; `words` dürfen nicht brechen.
        case wrapping(Text, words: [Word])
    }

    let title: Title
    let detail: HeaderDetail?
    let severity: Severity?
    /// S7: Der Zustandspunkt steht rechts in der Detailzeile, der Titel wird 12 pt breiter.
    var dotInDetail = false

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            RobotIcon(size: WidgetMetric.robot).frame(height: 16)
            VStack(alignment: .leading, spacing: 2) {
                titleView
                if dotInDetail {
                    OneLine {
                        HStack(spacing: 0) {
                            if let detail, !detail.isEmpty {
                                detail.textView.monospacedDigit().lineBox(.meta)
                            }
                            Spacer(minLength: WidgetSpace.small)
                            StatusDot(severity: severity)
                        }
                        .rowBox(WidgetFont.meta.lineHeight)
                    }
                } else if let detail, !detail.isEmpty {
                    OneLine {
                        detail.textView.monospacedDigit().lineBox(.meta)
                    }
                }
            }
            .padding(.leading, WidgetSpace.small)
            .frame(maxWidth: .infinity, alignment: .leading)
            if !dotInDetail {
                StatusDot(severity: severity).frame(height: 16).padding(.leading, WidgetSpace.small)
            }
        }
    }

    @ViewBuilder
    private var titleView: some View {
        switch title {
        case .split(let title):
            VStack(alignment: .leading, spacing: 0) {
                Line(Text(title.provider + " ·").token(.title), .title)
                Line(Text(title.account ?? "").token(.title, weight: .regular), .title)
            }
        case .wrapping(let text, let words):
            CappedText(text: text, font: .title, lines: 2, words: words)
        }
    }
}

// MARK: - Meter

/// Meter-Block: Name · Prozent (14) · 3 · Balken 6 · 3 · Reset (12) · Pace (12) = 50 pt;
/// ohne Reset und Pace (Ollama) 23 pt. Reset und Pace stehen in allen Größen untereinander.
struct MeterBlock: View {
    let window: LimitWindow
    let now: Date
    /// Zusatz („7 d“, „Wochenlimit“) nur im großen Widget und nur, wenn er passt.
    var showScope = false

    var body: some View {
        let elapsed = window.elapsedFraction(now: now)
        VStack(alignment: .leading, spacing: 0) {
            ViewThatFits(in: .horizontal) {
                if showScope, let scope = window.scopeNote { nameRow(scope: scope) }
                nameRow(scope: nil)
                Color.clear.frame(width: 0, height: WidgetFit.overflow)
            }
            MeterBar(percent: window.percent, elapsed: elapsed, color: window.severity.color, markHeight: WidgetMetric.mark)
                .frame(height: WidgetMetric.bar)
                .padding(.top, WidgetSpace.tight)
            // Ollama nennt keine Reset-Zeiten – dann bleiben die Zeilen weg statt leer.
            if window.resetsAt != nil || elapsed != nil {
                VStack(alignment: .leading, spacing: 0) {
                    if let resetsAt = window.resetsAt {
                        Line(Text("Reset \(Format.reset(resetsAt, now: now))").token(.meta).foregroundStyle(.secondary), .meta)
                    }
                    if let elapsed, let windowLength = window.windowLength {
                        let onPace = abs(window.percent - elapsed) < Format.paceTolerance
                        Line(Text(Format.pace(percent: window.percent, elapsed: elapsed, windowLength: windowLength))
                            .token(.meta, weight: onPace ? .regular : .semibold)
                            .foregroundStyle(onPace ? Color.secondary : window.severity.color), .meta)
                    }
                }
                .monospacedDigit()
                .padding(.top, WidgetSpace.tight)
            }
        }
    }

    private func nameRow(scope: String?) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 0) {
            Text(window.name).token(.row).lineBox(.row)
            if let scope {
                Text(scope).token(.meta).foregroundStyle(.secondary).lineBox(.meta)
                    .padding(.leading, WidgetSpace.small)
            }
            Spacer(minLength: WidgetSpace.small)
            PercentLabel(window: window)
        }
        .rowBox(WidgetFont.row.lineHeight)
    }
}

/// Prozent in Zustandsfarbe (Schwellen aus `Severity`: ab 80 % warn, ab 100 % crit),
/// Tabellenziffern, einzeilig, rechtsbündig in mindestens 38 pt.
struct PercentLabel: View {
    let window: LimitWindow

    var body: some View {
        Text(Format.percent(window.percent)).token(.row)
            .foregroundStyle(window.severity.color)
            .monospacedDigit()
            .lineLimit(1)
            .frame(height: WidgetFont.row.lineHeight)
            .fixedSize()
            .frame(minWidth: WidgetMetric.percentColumn, alignment: .trailing)
    }
}

/// Kurzmeter (letzte Stufen klein/mittel): eine Zeile, 14 pt – Name · Balken 4 · Prozent.
struct ShortMeter: View {
    let window: LimitWindow
    let now: Date

    var body: some View {
        OneLine {
            HStack(spacing: WidgetSpace.medium) {
                Text(window.name).token(.row).lineBox(.row)
                MeterBar(percent: window.percent, elapsed: window.elapsedFraction(now: now),
                         color: window.severity.color, markHeight: WidgetMetric.shortMark)
                    .frame(minWidth: 24)
                    .frame(height: WidgetMetric.shortBar)
                PercentLabel(window: window)
            }
            .rowBox(WidgetFont.row.lineHeight)
        }
    }
}

/// Meter-Blöcke in Spalten (Abstand 16), Zeilen 8 auseinander, oben bündig.
struct MeterGrid: View {
    let windows: [LimitWindow]
    let now: Date
    var showScope = false
    /// 2, im extragroßen Widget bei ein bis zwei Konten 4 (Stufe X1).
    var columns = 2

    var body: some View {
        let rows = stride(from: 0, to: windows.count, by: columns).map { Array(windows[$0..<min($0 + columns, windows.count)]) }
        VStack(alignment: .leading, spacing: WidgetSpace.medium) {
            ForEach(rows.indices, id: \.self) { index in
                HStack(alignment: .top, spacing: WidgetSpace.column) {
                    ForEach(rows[index]) { window in
                        MeterBlock(window: window, now: now, showScope: showScope)
                            .frame(maxWidth: .infinity, alignment: .topLeading)
                    }
                    ForEach(rows[index].count..<columns, id: \.self) { _ in
                        Color.clear.frame(maxWidth: .infinity, maxHeight: 0)
                    }
                }
            }
        }
    }
}

/// Meter-Blöcke untereinander (kleines Widget).
struct MeterColumn: View {
    let windows: [LimitWindow]
    let now: Date

    var body: some View {
        VStack(alignment: .leading, spacing: WidgetSpace.medium) {
            ForEach(windows) { MeterBlock(window: $0, now: now) }
        }
    }
}

/// Knappe Stufen: das knappste Limit als Meter-Block, die übrigen als Kurzmeter.
struct MeterCompact: View {
    let windows: [LimitWindow]
    let now: Date

    var body: some View {
        VStack(alignment: .leading, spacing: WidgetSpace.medium) {
            if let first = windows.first {
                MeterBlock(window: first, now: now)
                ForEach(windows.dropFirst()) { ShortMeter(window: $0, now: now) }
            }
        }
    }
}

/// Fehlerhinweis mit Warnsymbol, z. B. „Anmeldung abgelaufen. In Token Stats neu anmelden.“
struct FailureNote: View {
    let message: String
    var font: WidgetFont = .note
    var lines = 4

    var body: some View {
        CappedText(text: (warningSymbol() + Text(" ") + Text(message).token(font).foregroundStyle(.secondary)),
                   font: font, lines: lines)
    }
}

/// Wenn noch kein Stand und kein Hinweis da ist.
let noDataMessage = "Noch kein Stand – Token Stats fragt beim nächsten Takt ab."
