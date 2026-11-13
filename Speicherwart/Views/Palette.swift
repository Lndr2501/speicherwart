import AppKit
import SwiftUI

/// Geprüfte Kategorie-Palette (feste Reihenfolge, eigene Stufen für hell/dunkel).
enum Palette {
    private static let light = ["#2a78d6", "#eb6834", "#1baf7a", "#eda100", "#e87ba4", "#008300", "#6250d6", "#e34948"]
    private static let dark = ["#3987e5", "#d95926", "#199e70", "#c98500", "#d55181", "#008300", "#9085e9", "#e66767"]

    /// Slot 0–7. Alles darüber hinaus ist „Weitere“ und grau.
    static func slot(_ i: Int) -> Color {
        guard (0..<light.count).contains(i) else { return other }
        return dynamic(light[i], dark[i])
    }

    static let other = dynamic("#a9a8a1", "#5c5b57")

    private static func dynamic(_ l: String, _ d: String) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? hex(d) : hex(l)
        })
    }

    private static func hex(_ s: String) -> NSColor {
        let v = UInt32(s.dropFirst(), radix: 16) ?? 0
        return NSColor(
            srgbRed: CGFloat((v >> 16) & 0xff) / 255, green: CGFloat((v >> 8) & 0xff) / 255,
            blue: CGFloat(v & 0xff) / 255, alpha: 1
        )
    }
}
