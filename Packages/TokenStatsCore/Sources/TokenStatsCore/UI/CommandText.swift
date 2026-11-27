import SwiftUI

/// Hinweis mit Befehlen: Ein Befehl in »…« steht als eigene Zeile in Monospace und bricht nur
/// an Leerzeichen um, nie mitten in `CLAUDE_CONFIG_DIR=~/.claude-2` (Designer-Prüfung PR #5).
/// Die Satzteile umbrechen normal. Gemeinsam für Popover, Einstellungen und Widgets.
public enum CommandSplit {
    public enum Part: Equatable, Sendable {
        case text(String)
        case command(String)
    }

    /// Zerlegt „Im Terminal »CLAUDE_CONFIG_DIR=~/x claude« starten.“ in Satzteile und Befehle.
    /// Leere Teile entfallen; ohne »…« ist das Ergebnis der Text selbst.
    public static func parts(_ text: String) -> [Part] {
        var parts: [Part] = []
        var rest = Substring(text)
        while let open = rest.firstIndex(of: "»"), let close = rest[open...].firstIndex(of: "«") {
            let before = rest[..<open].trimmingCharacters(in: .whitespaces)
            if !before.isEmpty { parts.append(.text(before)) }
            let command = rest[rest.index(after: open)..<close].trimmingCharacters(in: .whitespaces)
            if !command.isEmpty { parts.append(.command(command)) }
            rest = rest[rest.index(after: close)...]
            // Satzzeichen direkt hinter dem Befehl gehören zum Befehl und entfallen mit »…«,
            // sonst begänne die nächste Zeile mit „.“ (wie die Windows-Fassung).
            while let first = rest.first, ".,;:".contains(first) { rest = rest.dropFirst() }
        }
        let tail = rest.trimmingCharacters(in: .whitespaces)
        if !tail.isEmpty { parts.append(.text(tail)) }
        return parts
    }
}

/// Text mit Befehlszeilen (`CommandSplit`). Schrift, Farbe und Größe erbt er vom Umfeld.
public struct CommandText: View {
    let text: String
    var spacing: CGFloat

    public init(_ text: String, spacing: CGFloat = 2) {
        self.text = text
        self.spacing = spacing
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: spacing) {
            ForEach(Array(CommandSplit.parts(text).enumerated()), id: \.offset) { _, part in
                switch part {
                case .text(let sentence):
                    Text(verbatim: sentence).fixedSize(horizontal: false, vertical: true)
                case .command(let command):
                    CommandRow(command: command)
                }
            }
        }
    }
}

/// Ein Befehl: eigene Zeile in Monospace (Designer-Prüfung PR #5, Runde 2). Umbrochen wird
/// zuerst an Leerzeichen, ist ein Teil zu breit nach `/ = _ - . :` (ohne Trennstrich), erst
/// als letzter Ausweg nach einem beliebigen Zeichen. Folgezeilen sind 2 Zeichen eingerückt.
/// Nie breiter als angeboten, nie abgeschnitten. „Befehl kopieren“ kopiert den ganzen Befehl.
public struct CommandRow: View {
    let command: String

    public init(command: String) {
        self.command = command
    }

    public var body: some View {
        CommandWrapLayout(characters: Array(command)) {
            ForEach(Array(command.enumerated()), id: \.offset) { _, character in
                Text(verbatim: String(character)).monospaced().fixedSize()
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: command))
        #if os(macOS)
        .contextMenu {
            Button("Befehl kopieren") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(command, forType: .string)
            }
        }
        #endif
    }
}

/// Umbruch eines Befehls, rein und testbar: welche Zeichen in welcher Zeile stehen.
public enum CommandWrap {
    /// Nach diesen Zeichen darf ein zu langer Teil umbrechen; das Zeichen bleibt am Zeilenende.
    public static let softBreaks: Set<Character> = ["/", "=", "_", "-", ".", ":"]
    /// Einzug der Folgezeilen, in Zeichen.
    public static let indentCharacters = 2

    /// Rangfolge der Bruchstellen nach einem Zeichen, wenn kein Leerzeichen passt (Designer-
    /// Prüfung PR #5, Runde 3): erst „=“, dann „/“, dann „- _ . :“. So wandert ein Pfadstück
    /// ganz in die nächste Zeile, wenn es dort passt.
    static let breakRanks: [Set<Character>] = [["="], ["/"], ["-", "_", ".", ":"]]

    /// Letzte erlaubte Bruchstelle des höchsten Rangs in `range`. Nie nach einem „.“, mit dem
    /// ein Name beginnt (`~/.claude`, `=.codex`, `.claude` am Zeilenanfang).
    static func softBreak(_ characters: [Character], in range: Range<Int>) -> Int? {
        func allowed(_ index: Int) -> Bool {
            guard characters[index] == "." else { return true }
            guard index > range.lowerBound else { return false }
            return !["/", "\\", "=", "~", " ", "\""].contains(characters[index - 1])
        }
        for rank in breakRanks {
            if let index = range.last(where: { rank.contains(characters[$0]) && allowed($0) }) { return index }
        }
        return nil
    }

    /// Zeilen als Bereiche in `characters`. `available` gilt für die erste Zeile, Folgezeilen
    /// haben `indent` weniger. Leerzeichen am Bruch entfallen. Jede Zeile hat mindestens ein
    /// Zeichen, auch wenn es allein schon zu breit ist.
    public static func lines(_ characters: [Character], widths: [CGFloat], available: CGFloat, indent: CGFloat) -> [Range<Int>] {
        let count = characters.count
        var result: [Range<Int>] = []
        var start = 0
        while start < count {
            if !result.isEmpty {
                while start < count, characters[start] == " " { start += 1 }
                if start >= count { break }
            }
            let limit = available - (result.isEmpty ? 0 : indent)
            var used: CGFloat = 0
            var end = start
            while end < count, used + widths[end] <= limit + 0.001 {
                used += widths[end]
                end += 1
            }
            if end == start { end = start + 1 }
            if end >= count {
                result.append(start..<count)
                break
            }
            if characters[end] == " " {
                result.append(start..<end)
                start = end
            } else if let space = (start..<end).last(where: { characters[$0] == " " }), space > start {
                result.append(start..<space)
                start = space + 1
            } else if let soft = softBreak(characters, in: start..<end) {
                result.append(start..<(soft + 1))
                start = soft + 1
            } else {
                result.append(start..<end)
                start = end
            }
        }
        return result
    }
}

/// Legt die Zeichen eines Befehls nach `CommandWrap.lines` in Zeilen.
struct CommandWrapLayout: Layout {
    let characters: [Character]

    private func lines(_ subviews: Subviews, width: CGFloat) -> (lines: [Range<Int>], widths: [CGFloat], height: CGFloat, indent: CGFloat) {
        let sizes = subviews.map { $0.sizeThatFits(.unspecified) }
        let widths = sizes.map(\.width)
        let indent = CGFloat(CommandWrap.indentCharacters) * (widths.first ?? 0)
        let lines = CommandWrap.lines(characters, widths: widths, available: width, indent: indent)
        return (lines, widths, sizes.map(\.height).max() ?? 0, indent)
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let available = proposal.width ?? .infinity
        let layout = lines(subviews, width: available)
        let widest = layout.lines.enumerated().map { index, line in
            (index == 0 ? 0 : layout.indent) + line.map { layout.widths[$0] }.reduce(0, +)
        }.max() ?? 0
        // Nie mehr als angeboten – sonst wird das Umfeld breiter und schneidet ab.
        return CGSize(width: min(widest, available), height: CGFloat(layout.lines.count) * layout.height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let layout = lines(subviews, width: bounds.width)
        var placed = Set<Int>()
        for (index, line) in layout.lines.enumerated() {
            var x = bounds.minX + (index == 0 ? 0 : layout.indent)
            let y = bounds.minY + CGFloat(index) * layout.height
            for character in line {
                subviews[character].place(at: CGPoint(x: x, y: y), proposal: .unspecified)
                x += layout.widths[character]
                placed.insert(character)
            }
        }
        // Leerzeichen am Bruch: unsichtbar an den Anfang.
        for index in subviews.indices where !placed.contains(index) {
            subviews[index].place(at: CGPoint(x: bounds.minX, y: bounds.minY), proposal: .zero)
        }
    }
}

/// Teile nebeneinander, bei Platzmangel in die nächste Zeile – ohne einen Teil zu kürzen.
/// Meldet nie mehr Breite als angeboten.
struct TokenFlow: Layout {
    var spacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let available = proposal.width ?? .infinity
        let rows = arrange(subviews, width: available)
        let width = rows.map(\.width).max() ?? 0
        let height = rows.map(\.height).reduce(0, +)
        return CGSize(width: min(width, available), height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in arrange(subviews, width: bounds.width) {
            var x = bounds.minX
            for index in row.indices {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
            y += row.height
        }
    }

    private struct Row {
        var indices: [Int] = []
        var width: CGFloat = 0
        var height: CGFloat = 0
    }

    private func arrange(_ subviews: Subviews, width: CGFloat) -> [Row] {
        var rows: [Row] = []
        var row = Row()
        for (index, subview) in subviews.enumerated() {
            let size = subview.sizeThatFits(.unspecified)
            if !row.indices.isEmpty, row.width + spacing + size.width > width {
                rows.append(row)
                row = Row()
            }
            row.width += (row.indices.isEmpty ? 0 : spacing) + size.width
            row.height = max(row.height, size.height)
            row.indices.append(index)
        }
        if !row.indices.isEmpty { rows.append(row) }
        return rows
    }
}
