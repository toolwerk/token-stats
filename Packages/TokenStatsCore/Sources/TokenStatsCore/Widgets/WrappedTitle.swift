import CoreText
import SwiftUI
#if canImport(AppKit)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif

/// Umbruch von Kontotiteln wie „Claude · Agentur Nord“, gemessen statt gezählt (Designer-
/// Prüfung PR #5, Runden 6 und 7). Rein und testbar; `WrappedTitle` zeichnet danach.
///
/// Regeln:
/// - Umbrochen wird nach Leerzeichen und Bindestrichen, nie mitten im Wort.
/// - Passt der Titel nicht in eine Zeile, aber „· Kontoname“ ganz, wird dort geteilt
///   („Claude“ / „· Agentur Nord“).
/// - Sonst beginnt der Trennpunkt die neue Zeile, wenn „· Wort“ dort ganz passt; andernfalls
///   bleibt er am Ende der Vorzeile („Claude ·“ / „MÖBELWERKSTATT“).
/// - Ist ein einzelnes Wort allein breiter als die Zeile, bricht es als letzter Ausweg nach
///   einem beliebigen Zeichen (Stufe S8 des Entwurfs), und das letzte Stück hat mindestens
///   3 Zeichen – kein einzelnes „T“. Die Tabelle des großen Widgets vermeidet das ganz (L5).
///
/// Gemessen wird immer der ganze Zeilentext (`width`), mit Kerning – nicht die Summe der
/// Einzelzeichen, die bei Großbuchstaben 2–3 pt zu breit ist.
public enum TitleWrap {
    /// Mindestlänge des letzten Stücks beim Zeichenumbruch.
    public static let minimumTail = 3

    public static func lines(_ characters: [Character], available: CGFloat, width: (Range<Int>) -> CGFloat) -> [Range<Int>] {
        let count = characters.count
        func breakable(_ position: Int) -> Bool {
            position > 0 && position < count && (characters[position - 1] == " " || characters[position - 1] == "-")
        }
        func trimmed(_ range: Range<Int>) -> Range<Int> {
            var end = range.upperBound
            while end > range.lowerBound, characters[end - 1] == " " { end -= 1 }
            return range.lowerBound..<end
        }
        func fits(_ range: Range<Int>) -> Bool { width(trimmed(range)) <= available + 0.001 }
        /// „· Wort“ ab `position` bis zur nächsten Bruchstelle nach dem Wort.
        func segment(from position: Int, skippingFirst: Int) -> Range<Int> {
            var end = min(position + skippingFirst + 1, count)
            while end < count, !breakable(end) { end += 1 }
            return trimmed(position..<end)
        }

        if !fits(0..<count), let separator = (0..<max(count - 2, 0)).first(where: {
            characters[$0] == " " && characters[$0 + 1] == "·" && characters[$0 + 2] == " "
        }) {
            let kind = 0..<separator
            let rest = (separator + 1)..<count
            if fits(kind), fits(rest) { return [kind, rest] }
        }

        var result: [Range<Int>] = []
        var start = 0
        while start < count {
            while start < count, characters[start] == " " { start += 1 }
            if start >= count { break }
            var end = start
            while end < count, fits(start..<(end + 1)) { end += 1 }
            if end >= count {
                result.append(trimmed(start..<count))
                break
            }
            if end == start { end = start + 1 }
            var candidates = (start + 1...end).filter(breakable)
            if characters[end] == " " { candidates.append(end + 1) }
            guard var position = candidates.last else {
                // Zeichenumbruch: das letzte Stück des Wortes nicht kürzer als `minimumTail`.
                var wordEnd = end
                while wordEnd < count, !breakable(wordEnd), characters[wordEnd] != " " { wordEnd += 1 }
                if wordEnd - end < minimumTail, wordEnd - minimumTail > start {
                    end = wordEnd - minimumTail
                }
                result.append(start..<end)
                start = end
                continue
            }
            if position - 2 > start, characters[position - 2] == "·", candidates.contains(position - 2),
               fits(segment(from: position - 2, skippingFirst: 2)) {
                position -= 2
            }
            result.append(trimmed(start..<position))
            start = position
        }
        return result
    }

    /// Für Tests und einfache Fälle: Breite als Summe fester Zeichenbreiten.
    public static func lines(_ characters: [Character], widths: [CGFloat], available: CGFloat) -> [Range<Int>] {
        lines(characters, available: available) { range in range.map { widths[$0] }.reduce(0, +) }
    }

    /// Alle unterschiedlichen Umbrüche von breit nach schmal – für `ViewThatFits`, das dann die
    /// erste Fassung nimmt, deren Zeilen wirklich passen.
    /// Schmaler als das wird kein Titel gesetzt: Die schmalste Spalte (Kontoname in der Tabelle
    /// der kleinsten großen Kachel) ist rund 100 pt breit.
    public static let narrowest: CGFloat = 60

    public static func variants(_ characters: [Character], width: (Range<Int>) -> CGFloat) -> [[Range<Int>]] {
        var result: [[Range<Int>]] = []
        var available = width(0..<characters.count)
        for _ in 0..<24 {
            let lines = lines(characters, available: available, width: width)
            if result.last != lines { result.append(lines) }
            let widest = lines.map(width).max() ?? 0
            if widest <= narrowest || lines.allSatisfy({ $0.count <= 1 }) { break }
            available = widest - 0.5
        }
        return result
    }

    /// Breitestes Stück, das nie umbrechen darf (zwischen Leerzeichen und Bindestrichen) –
    /// zeigt, ob eine Spalte ohne Bruch im Wort auskommt.
    public static func widestUnbreakable(_ characters: [Character], width: (Range<Int>) -> CGFloat) -> CGFloat {
        var widest: CGFloat = 0
        var start = 0
        for index in characters.indices {
            let character = characters[index]
            if character == " " {
                if index > start { widest = max(widest, width(start..<index)) }
                start = index + 1
            } else if character == "-" {
                widest = max(widest, width(start..<(index + 1)))
                start = index + 1
            }
        }
        if characters.count > start { widest = max(widest, width(start..<characters.count)) }
        return widest
    }
}

/// Breite eines Textes in der Systemschrift, mit Kerning – wie SwiftUI ihn setzt.
public enum TextWidth {
    public static func measure(_ runs: [(text: String, weight: Font.Weight)], size: CGFloat) -> CGFloat {
        let string = NSMutableAttributedString()
        for run in runs where !run.text.isEmpty {
            string.append(NSAttributedString(string: run.text, attributes: [.font: font(size: size, weight: run.weight)]))
        }
        let line = CTLineCreateWithAttributedString(string)
        return CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
    }

    #if canImport(AppKit)
    private static func font(size: CGFloat, weight: Font.Weight) -> NSFont {
        let mapped: NSFont.Weight = switch weight {
        case .bold: .bold
        case .semibold: .semibold
        case .medium: .medium
        default: .regular
        }
        return NSFont.systemFont(ofSize: size, weight: mapped)
    }
    #else
    private static func font(size: CGFloat, weight: Font.Weight) -> UIFont {
        let mapped: UIFont.Weight = switch weight {
        case .bold: .bold
        case .semibold: .semibold
        case .medium: .medium
        default: .regular
        }
        return UIFont.systemFont(ofSize: size, weight: mapped)
    }
    #endif
}

/// Titel, umbrochen nach `TitleWrap`. Jede Zeile ist ein eigener `Text` (mit Kerning);
/// `ViewThatFits` nimmt die erste Fassung, deren Zeilen in die angebotene Breite passen.
/// Der Anfang bis `prefix` (Anbieter und Punkt) steht in `prefixWeight`, der Rest in `accountWeight`.
public struct WrappedTitle: View {
    let characters: [Character]
    let size: CGFloat
    let boldCount: Int
    let prefixWeight: Font.Weight
    let accountWeight: Font.Weight
    let variants: [[Range<Int>]]

    public init(_ text: String, size: CGFloat, prefix: String? = nil,
                prefixWeight: Font.Weight = .bold, accountWeight: Font.Weight = .bold) {
        let characters = Array(text)
        let boldCount = prefix.map { text.hasPrefix($0) ? $0.count : text.count } ?? text.count
        self.characters = characters
        self.size = size
        self.boldCount = boldCount
        self.prefixWeight = prefixWeight
        self.accountWeight = accountWeight
        variants = Self.cachedVariants(characters, size: size, boldCount: boldCount, prefixWeight, accountWeight)
    }

    /// Die Varianten hängen nur von Text, Größe und Gewichten ab – einmal rechnen, dann
    /// wiederverwenden (das große Widget legt jede Tabellenzeile in mehreren Stufen an).
    private static var cache: [String: [[Range<Int>]]] = [:]

    private static func cachedVariants(_ characters: [Character], size: CGFloat, boldCount: Int,
                                       _ prefixWeight: Font.Weight, _ accountWeight: Font.Weight) -> [[Range<Int>]] {
        let key = "\(String(characters))|\(size)|\(boldCount)|\(prefixWeight)|\(accountWeight)"
        if let hit = cache[key] { return hit }
        var measured: [Range<Int>: CGFloat] = [:]
        let variants = TitleWrap.variants(characters) { range in
            if let width = measured[range] { return width }
            let width = TextWidth.measure(runs(characters, range, boldCount: boldCount, prefixWeight, accountWeight), size: size)
            measured[range] = width
            return width
        }
        if cache.count > 500 { cache.removeAll() }
        cache[key] = variants
        return variants
    }

    /// Breite des breitesten unteilbaren Stücks dieses Titels.
    public nonisolated static func widestUnbreakable(_ text: String, size: CGFloat, prefix: String? = nil,
                                         prefixWeight: Font.Weight = .bold, accountWeight: Font.Weight = .bold) -> CGFloat {
        let characters = Array(text)
        let boldCount = prefix.map { text.hasPrefix($0) ? $0.count : text.count } ?? text.count
        return TitleWrap.widestUnbreakable(characters) { range in
            TextWidth.measure(runs(characters, range, boldCount: boldCount, prefixWeight, accountWeight), size: size)
        }
    }

    /// Zeilen, die der Titel bei `available` Breite braucht – mit dem echten Umbruch gemessen.
    public nonisolated static func lineCount(_ text: String, size: CGFloat, prefix: String? = nil,
                                             prefixWeight: Font.Weight = .bold, accountWeight: Font.Weight = .bold,
                                             available: CGFloat) -> Int {
        let characters = Array(text)
        let boldCount = prefix.map { text.hasPrefix($0) ? $0.count : text.count } ?? text.count
        return TitleWrap.lines(characters, available: available) { range in
            TextWidth.measure(runs(characters, range, boldCount: boldCount, prefixWeight, accountWeight), size: size)
        }.count
    }

    /// Text einer Zeile in zwei Läufen: Anbieterteil und Kontoteil.
    nonisolated static func runs(_ characters: [Character], _ range: Range<Int>, boldCount: Int,
                     _ prefixWeight: Font.Weight, _ accountWeight: Font.Weight) -> [(text: String, weight: Font.Weight)] {
        let split = min(max(boldCount, range.lowerBound), range.upperBound)
        return [(String(characters[range.lowerBound..<split]), prefixWeight),
                (String(characters[split..<range.upperBound]), accountWeight)]
    }

    public var body: some View {
        ViewThatFits(in: .horizontal) {
            ForEach(variants.indices, id: \.self) { index in
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(variants[index].indices, id: \.self) { line in
                        lineText(variants[index][line]).lineLimit(1).fixedSize()
                    }
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: String(characters)))
    }

    private func lineText(_ range: Range<Int>) -> Text {
        let parts = Self.runs(characters, range, boldCount: boldCount, prefixWeight, accountWeight)
        return Text(verbatim: parts[0].text).font(.system(size: size, weight: parts[0].weight))
            + Text(verbatim: parts[1].text).font(.system(size: size, weight: parts[1].weight))
    }
}
