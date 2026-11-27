import Foundation
import Testing
@testable import TokenStatsCore

// Hinweissätze in Zustandsfarbe (Designer-Prüfung PR #5, Runde 12): mindestens 4,5:1 (WCAG AA)
// auf der getönten Hinweisfläche – 12 % der Zustandsfarbe über dem Fenstergrund.

@Suite struct ContrastTests {
    private func luminance(_ hex: UInt32) -> Double {
        func channel(_ shift: UInt32) -> Double {
            let value = Double((hex >> shift) & 0xFF) / 255
            return value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * channel(16) + 0.7152 * channel(8) + 0.0722 * channel(0)
    }

    private func contrast(_ a: UInt32, _ b: UInt32) -> Double {
        let (high, low) = (max(luminance(a), luminance(b)), min(luminance(a), luminance(b)))
        return (high + 0.05) / (low + 0.05)
    }

    private func tint(_ color: UInt32, over base: UInt32, opacity: Double = 0.12) -> UInt32 {
        var result: UInt32 = 0
        for shift: UInt32 in [16, 8, 0] {
            let fg = Double((color >> shift) & 0xFF)
            let bg = Double((base >> shift) & 0xFF)
            let mixed = (opacity * fg + (1 - opacity) * bg).rounded()
            result |= UInt32(mixed) << shift
        }
        return result
    }

    // Fenstergründe: macOS-Einstellungen (Gruppe hell/dunkel), Windows (#202020), Popover.
    private let lightBases: [UInt32] = [0xFFFFFF, 0xF6F6F6, 0xF0F0F0]
    private let darkBases: [UInt32] = [0x393637, 0x323233, 0x2C2C2C, 0x202020]

    @Test(arguments: [Severity.warn, .crit])
    func noticeTextReachesAA(_ severity: Severity) {
        for base in lightBases {
            let background = tint(severity.hexValues.light, over: base)
            #expect(contrast(severity.textHexValues.light, background) >= 4.5, "hell auf \(String(base, radix: 16))")
        }
        for base in darkBases {
            let background = tint(severity.hexValues.dark, over: base)
            #expect(contrast(severity.textHexValues.dark, background) >= 4.5, "dunkel auf \(String(base, radix: 16))")
        }
    }

    @Test func oldDarkRedFailed() {
        // Gegenprobe: das alte Rot als Text lag auf der dunklen Einstellungsfläche unter 4,5:1.
        #expect(contrast(Severity.crit.hexValues.dark, tint(Severity.crit.hexValues.dark, over: 0x393637)) < 4.5)
    }
}
