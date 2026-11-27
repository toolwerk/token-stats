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

/// Ein Befehl: Monospace, je Token nicht umbrechend, Umbruch nur an Leerzeichen.
public struct CommandRow: View {
    let command: String

    public init(command: String) {
        self.command = command
    }

    public var body: some View {
        TokenFlow(spacing: 0) {
            let tokens = command.split(separator: " ", omittingEmptySubsequences: true)
            // Leerzeichen hinten am Token: am Zeilenende unsichtbar, am Zeilenanfang kein Einzug.
            ForEach(Array(tokens.enumerated()), id: \.offset) { index, token in
                Text(verbatim: index == tokens.count - 1 ? String(token) : token + " ")
                    .monospaced()
                    .lineLimit(1)
                    .fixedSize()
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

/// Teile nebeneinander, bei Platzmangel in die nächste Zeile – ohne einen Teil zu kürzen.
struct TokenFlow: Layout {
    var spacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(subviews, width: proposal.width ?? .infinity)
        let width = rows.map(\.width).max() ?? 0
        let height = rows.map(\.height).reduce(0, +)
        return CGSize(width: width, height: height)
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
