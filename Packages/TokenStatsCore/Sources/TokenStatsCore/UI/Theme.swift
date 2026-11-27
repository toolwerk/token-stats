import SwiftUI
#if canImport(AppKit)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif

/// Zustandsfarben aus dem Entwurf, je für Hell und Dunkel.
extension Severity {
    var hexValues: (light: UInt32, dark: UInt32) {
        switch self {
        case .ok: (0x2F8F5B, 0x4CBE83)
        case .warn: (0xC1860F, 0xE0A838)
        case .crit: (0xC04329, 0xE7705A)
        }
    }

    public var color: Color { Color.dynamic(light: hexValues.light, dark: hexValues.dark) }

    /// Farbe für **Hinweissätze** (Designer-Prüfung PR #5, Runde 12): mindestens 4,5:1 auf der
    /// getönten Hinweisfläche (12 % der Zustandsfarbe), auch gemessen an den Pixeln der 10-pt-Schrift.
    /// Mit `color` wären es nur Rot dunkel #E7705A auf #4E3D3B 3,3:1 (jetzt #F59A8A, 4,8:1),
    /// Rot hell #C04329 auf #F3E7E4 4,3:1 (jetzt #952F1A, 6,4:1), Gelb hell #C1860F auf #F3EDE1
    /// 2,2:1 (jetzt #744F00, 6,3:1), Gelb dunkel #E0A838 auf #4D4437 knapp unter 4,5:1 (jetzt
    /// #E8B24A, 5,0:1). Hell liegen die Pixel der Kantenglättung wegen heller als der Sollwert,
    /// darum dort mit Abstand. Balken, Prozente und Punkte bleiben bei `color`. Geprüft in `ContrastTests`.
    public var textColor: Color { Color.dynamic(light: textHexValues.light, dark: textHexValues.dark) }

    var textHexValues: (light: UInt32, dark: UInt32) {
        switch self {
        case .ok: hexValues
        case .warn: (0x744F00, 0xE8B24A)
        case .crit: (0x952F1A, 0xF59A8A)
        }
    }

    #if canImport(AppKit)
    public var nsColor: NSColor { .dynamic(light: hexValues.light, dark: hexValues.dark) }
    #endif
}

extension Color {
    /// Löst je nach Erscheinungsbild auf – in der App, im Widget und auf iOS gleich.
    public static func dynamic(light: UInt32, dark: UInt32) -> Color {
        #if canImport(AppKit)
        Color(nsColor: .dynamic(light: light, dark: dark))
        #else
        Color(uiColor: UIColor { traits in
            UIColor(hex: traits.userInterfaceStyle == .dark ? dark : light)
        })
        #endif
    }
}

#if canImport(AppKit)
extension NSColor {
    public static func dynamic(light: UInt32, dark: UInt32) -> NSColor {
        NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            return NSColor(hex: isDark ? dark : light)
        }
    }

    public convenience init(hex: UInt32) {
        self.init(
            srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: 1
        )
    }
}
#elseif canImport(UIKit)
extension UIColor {
    public convenience init(hex: UInt32) {
        self.init(
            red: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: 1
        )
    }
}
#endif

/// Roboterkopf aus dem Entwurf, in einem 24×24-Raster gezeichnet.
public enum RobotGlyph {
    /// Linien: Kopf, Antenne, Mund, Ohren.
    public static func strokes(in rect: CGRect) -> CGPath {
        let path = CGMutablePath()
        let t = transform(for: rect)
        path.addPath(CGPath(roundedRect: CGRect(x: 4, y: 8, width: 16, height: 11), cornerWidth: 3.2, cornerHeight: 3.2, transform: nil))
        path.move(to: CGPoint(x: 12, y: 4.2)); path.addLine(to: CGPoint(x: 12, y: 8))
        path.move(to: CGPoint(x: 9.5, y: 16.3)); path.addLine(to: CGPoint(x: 14.5, y: 16.3))
        path.move(to: CGPoint(x: 4, y: 11.5)); path.addLine(to: CGPoint(x: 2.4, y: 11.5))
        path.move(to: CGPoint(x: 20, y: 11.5)); path.addLine(to: CGPoint(x: 21.6, y: 11.5))
        return path.copy(using: [t]) ?? path
    }

    /// Flächen: Augen und Antennenkugel.
    public static func fills(in rect: CGRect) -> CGPath {
        let path = CGMutablePath()
        let t = transform(for: rect)
        path.addEllipse(in: CGRect(x: 9 - 1.35, y: 13 - 1.35, width: 2.7, height: 2.7))
        path.addEllipse(in: CGRect(x: 15 - 1.35, y: 13 - 1.35, width: 2.7, height: 2.7))
        path.addEllipse(in: CGRect(x: 12 - 1.3, y: 3.4 - 1.3, width: 2.6, height: 2.6))
        return path.copy(using: [t]) ?? path
    }

    public static func lineWidth(in rect: CGRect) -> CGFloat { 1.8 * rect.width / 24 }

    private static func transform(for rect: CGRect) -> CGAffineTransform {
        let scale = min(rect.width, rect.height) / 24
        return CGAffineTransform(translationX: rect.minX, y: rect.minY).scaledBy(x: scale, y: scale)
    }
}

public struct RobotIcon: View {
    public var size: CGFloat

    public init(size: CGFloat = 15) {
        self.size = size
    }

    public var body: some View {
        Canvas { context, canvasSize in
            let rect = CGRect(origin: .zero, size: canvasSize)
            context.stroke(
                Path(RobotGlyph.strokes(in: rect)),
                with: .foreground,
                style: StrokeStyle(lineWidth: RobotGlyph.lineWidth(in: rect), lineCap: .round, lineJoin: .round)
            )
            context.fill(Path(RobotGlyph.fills(in: rect)), with: .foreground)
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}
