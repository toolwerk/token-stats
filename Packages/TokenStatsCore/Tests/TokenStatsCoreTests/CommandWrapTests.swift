import Foundation
import Testing
@testable import TokenStatsCore

// Umbruch von Befehlen (Designer-Prüfung PR #5, Runde 2): Leerzeichen zuerst, dann nach
// / = _ - . :, zuletzt hart; Folgezeilen 2 Zeichen eingerückt; nie breiter als verfügbar.
// Monospace: jedes Zeichen 1 breit, verfügbare Breite = Zeichen je Zeile.

@Suite struct CommandWrapTests {
    private func wrap(_ command: String, _ width: Int) -> [String] {
        let characters = Array(command)
        let lines = CommandWrap.lines(characters, widths: characters.map { _ in 1 }, available: CGFloat(width),
                                      indent: CGFloat(CommandWrap.indentCharacters))
        return lines.map { String(characters[$0]) }
    }

    private func fits(_ lines: [String], _ width: Int) -> Bool {
        lines.enumerated().allSatisfy { index, line in line.count + (index == 0 ? 0 : 2) <= width }
    }

    @Test func spacesFirst() {
        let lines = wrap("CLAUDE_CONFIG_DIR=~/.claude-arbeit claude auth login", 40)
        #expect(lines == ["CLAUDE_CONFIG_DIR=~/.claude-arbeit", "claude auth login"])
        #expect(fits(lines, 40))
    }

    @Test func fitsOnOneLine() {
        #expect(wrap("codex login", 40) == ["codex login"])
    }

    @Test func tooLongPartBreaksAfterSeparator() {
        // Kleines Widget: rund 20 Zeichen je Zeile.
        let lines = wrap("CLAUDE_CONFIG_DIR=~/claude-alt claude", 20)
        #expect(lines == ["CLAUDE_CONFIG_DIR=~/", "claude-alt claude"], "letzter Bruch nach „/“, der noch passt")
        #expect(fits(lines, 20))
    }

    @Test func breaksAfterSlashInLongPath() {
        let lines = wrap("CLAUDE_CONFIG_DIR=~/Projekte/kunden/schmidt-beratung/claude-konfiguration claude", 30)
        #expect(fits(lines, 30))
        #expect(lines.dropLast().allSatisfy { line in line.last.map { CommandWrap.softBreaks.contains($0) } ?? false }
                || lines.dropLast().contains { !$0.contains("/") }, "Brüche nach Trennzeichen oder Leerzeichen")
        #expect(lines.first == "CLAUDE_CONFIG_DIR=~/Projekte/")
    }

    @Test func hardBreakOnlyAsLastResort() {
        let lines = wrap("abcdefghijklmnopqrstuvwxyz", 10)
        #expect(lines == ["abcdefghij", "klmnopqr", "stuvwxyz"], "ohne Trennzeichen hart, Folgezeilen 2 eingerückt")
        #expect(fits(lines, 10))
    }

    @Test func neverLongerThanAvailable() {
        let command = "$env:CLAUDE_CONFIG_DIR=\"C:\\Daten\\kunde-a\"; claude auth login --mit-einem-sehr-langen-schalter"
        for width in 8...60 {
            let lines = wrap(command, width)
            #expect(fits(lines, width), "Breite \(width)")
            #expect(lines.joined().replacingOccurrences(of: " ", with: "") == command.replacingOccurrences(of: " ", with: ""),
                    "kein Zeichen geht verloren (Breite \(width))")
        }
    }
}
