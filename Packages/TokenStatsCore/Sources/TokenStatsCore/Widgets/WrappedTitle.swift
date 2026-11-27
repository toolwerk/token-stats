import SwiftUI

/// Umbruch von Kontotiteln wie „Claude · Agentur Nord“, gemessen statt gezählt (Designer-
/// Prüfung PR #5, Runde 6). Rein und testbar; `WrappedTitle` zeichnet danach.
///
/// Regeln:
/// - Umbrochen wird nach Leerzeichen und Bindestrichen, nie mitten im Wort.
/// - Der Trennpunkt beginnt die neue Zeile („Claude“ / „· Agentur Nord“), wenn „· Wort“ dort
///   ganz passt; sonst bleibt er am Ende der Vorzeile („Claude ·“ / „MÖBELWERKSTATT“).
/// - Ist ein einzelnes Wort allein breiter als die Zeile, bricht es als letzter Ausweg nach
///   einem beliebigen Zeichen – lieber getrennt als abgeschnitten oder im Innenrand.
public enum TitleWrap {
    public static func lines(_ characters: [Character], widths: [CGFloat], available: CGFloat) -> [Range<Int>] {
        let count = characters.count
        func breakable(_ position: Int) -> Bool {
            position > 0 && position < count && (characters[position - 1] == " " || characters[position - 1] == "-")
        }
        func width(_ range: Range<Int>) -> CGFloat { range.map { widths[$0] }.reduce(0, +) }
        /// Breite von `position` bis zur nächsten Bruchstelle danach, ohne Leerzeichen am Ende.
        func segmentWidth(from position: Int, skippingFirst: Int) -> CGFloat {
            // Ab dem ersten Zeichen nach dem Übersprungenen bis zur nächsten Bruchstelle.
            var end = min(position + skippingFirst + 1, count)
            while end < count, !breakable(end) { end += 1 }
            var last = end
            while last > position, characters[last - 1] == " " { last -= 1 }
            return width(position..<last)
        }

        // „Anbieter · Konto“: passt der Titel nicht in eine Zeile, aber „· Konto“ ganz, dann
        // genau dort teilen („Claude“ / „· Agentur Nord“) – der Kontoname bleibt zusammen.
        if width(0..<count) > available + 0.001, let separator = (0..<max(count - 2, 0)).first(where: {
            characters[$0] == " " && characters[$0 + 1] == "·" && characters[$0 + 2] == " "
        }) {
            let kind = 0..<separator
            let rest = (separator + 1)..<count
            if width(kind) <= available + 0.001, width(rest) <= available + 0.001 {
                return [kind, rest]
            }
        }

        var result: [Range<Int>] = []
        var start = 0
        while start < count {
            while start < count, characters[start] == " " { start += 1 }
            if start >= count { break }
            var used: CGFloat = 0
            var end = start
            while end < count, used + widths[end] <= available + 0.001 {
                used += widths[end]
                end += 1
            }
            if end >= count {
                result.append(start..<count)
                break
            }
            if end == start { end = start + 1 }
            // Leerzeichen am Ende der Zeile zählen nicht: Bricht es genau dort, ist das die Stelle.
            var candidates = (start + 1...end).filter(breakable)
            if end < count, characters[end] == " " { candidates.append(end + 1) }
            guard var position = candidates.last else {
                result.append(start..<end)
                start = end
                continue
            }
            // „· “ am Zeilenende: lieber vor dem Punkt brechen, wenn „· Wort“ in eine Zeile passt.
            if position - 2 > start, characters[position - 2] == "·", candidates.contains(position - 2),
               segmentWidth(from: position - 2, skippingFirst: 2) <= available + 0.001 {
                position -= 2
            }
            var lineEnd = position
            while lineEnd > start, characters[lineEnd - 1] == " " { lineEnd -= 1 }
            result.append(start..<lineEnd)
            start = position
        }
        return result
    }
}

/// Titel aus einzelnen Zeichen, umbrochen nach `TitleWrap`; meldet nie mehr Breite als
/// angeboten. `boldCount` Zeichen am Anfang (der Anbieter) sind fett, der Rest in `accountWeight`.
public struct WrappedTitle: View {
    let text: String
    let size: CGFloat
    let boldCount: Int
    let prefixWeight: Font.Weight
    let accountWeight: Font.Weight

    /// „Claude · Kunde A“: `prefix` (Anbieter und Punkt) in `prefixWeight`, der Rest in
    /// `accountWeight`; ohne `prefix` alles in `prefixWeight`.
    public init(_ text: String, size: CGFloat, prefix: String? = nil,
                prefixWeight: Font.Weight = .bold, accountWeight: Font.Weight = .bold) {
        self.text = text
        self.size = size
        self.boldCount = prefix.map { text.hasPrefix($0) ? $0.count : text.count } ?? text.count
        self.prefixWeight = prefixWeight
        self.accountWeight = accountWeight
    }

    public var body: some View {
        TitleWrapLayout(characters: Array(text)) {
            ForEach(Array(text.enumerated()), id: \.offset) { index, character in
                Text(verbatim: String(character))
                    .font(.system(size: size, weight: index < boldCount ? prefixWeight : accountWeight))
                    .fixedSize()
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: text))
    }
}

struct TitleWrapLayout: Layout {
    let characters: [Character]

    private func layout(_ subviews: Subviews, width: CGFloat) -> (lines: [Range<Int>], widths: [CGFloat], height: CGFloat) {
        let sizes = subviews.map { $0.sizeThatFits(.unspecified) }
        let widths = sizes.map(\.width)
        return (TitleWrap.lines(characters, widths: widths, available: width), widths, sizes.map(\.height).max() ?? 0)
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let available = proposal.width ?? .infinity
        let result = layout(subviews, width: available)
        let widest = result.lines.map { $0.map { result.widths[$0] }.reduce(0, +) }.max() ?? 0
        return CGSize(width: min(widest, available), height: CGFloat(result.lines.count) * result.height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let result = layout(subviews, width: bounds.width)
        var placed = Set<Int>()
        for (row, line) in result.lines.enumerated() {
            var x = bounds.minX
            for index in line {
                subviews[index].place(at: CGPoint(x: x, y: bounds.minY + CGFloat(row) * result.height), proposal: .unspecified)
                x += result.widths[index]
                placed.insert(index)
            }
        }
        for index in subviews.indices where !placed.contains(index) {
            subviews[index].place(at: CGPoint(x: bounds.minX, y: bounds.minY), proposal: .zero)
        }
    }
}
