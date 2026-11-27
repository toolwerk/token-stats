import SwiftUI
import TokenStatsCore
import WidgetKit

/// Widget-Erweiterung (Issue #10): „Verbrauch“ und „Limits“ für Mitteilungszentrale und
/// Schreibtisch. Liest nur `widgets.json` aus der App Group; alles Rechnen bleibt in der App.
/// Auf iOS (Issue #11) dieselben Quellen: Homescreen-Widgets aus dem iCloud-Cache der App,
/// dazu die Sperrbildschirm-Familien in LockScreenWidgets.swift.
#if DEBUG
import OSLog

/// Echte Kachelgröße je Familie, um sie gegen die Maße im Widget-Entwurf zu halten (164 / 344 × 164 /
/// 344 × 344 / 704 × 344 pt). Nur Debug: `log stream --predicate 'subsystem == "de.mahype.TokenStats"'`.
enum WidgetSizeLog {
    private static let logger = Logger(subsystem: "de.mahype.TokenStats", category: "widgets")

    static func log(_ kind: String, family: WidgetFamily, size: CGSize) {
        logger.debug("Widget \(kind, privacy: .public) \(String(describing: family), privacy: .public): \(Int(size.width))×\(Int(size.height)) pt")
    }
}
#endif

@main
struct TokenStatsWidgetBundle: WidgetBundle {
    var body: some Widget {
        UsageWidget()
        LimitsWidget()
    }
}

extension WidgetFamily {
    var size: WidgetSize {
        switch self {
        case .systemExtraLarge: .extraLarge
        case .systemLarge: .large
        case .systemMedium: .medium
        default: .small
        }
    }

    /// Sperrbildschirm und StandBy (nur iOS).
    var isAccessory: Bool {
        #if os(iOS)
        switch self {
        case .accessoryCircular, .accessoryRectangular, .accessoryInline: true
        default: false
        }
        #else
        false
        #endif
    }

    /// Extragroß nur auf dem Mac (dort nur auf dem Schreibtisch, nicht in der Mitteilungszentrale);
    /// die iOS-Fassung bleibt bei klein, mittel, groß.
    static var systemFamilies: [WidgetFamily] {
        #if os(macOS)
        [.systemSmall, .systemMedium, .systemLarge, .systemExtraLarge]
        #else
        [.systemSmall, .systemMedium, .systemLarge]
        #endif
    }

    static var limitsFamilies: [WidgetFamily] {
        #if os(iOS)
        systemFamilies + [.accessoryCircular, .accessoryRectangular, .accessoryInline]
        #else
        systemFamilies
        #endif
    }
}
