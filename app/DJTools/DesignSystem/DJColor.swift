import AppKit
import SwiftUI

/// DJ Tools' colour tokens: Wax Studio's `WaxColor` (the Wax dashboard's
/// shadcn variables), so the two apps read as siblings. Dynamic colours that
/// follow the window's appearance. Brand orange (`flame`) is only the wordmark's.
enum DJColor {
    // Foundation
    static let background = dynamic(light: 0xF3EDE0, dark: 0x1F1E1B)
    static let foreground = dynamic(light: 0x343330, dark: 0xF3EDE0)
    static let card = dynamic(light: 0xFBF7EB, dark: 0x2A2825)

    // Primary: charcoal CTAs in light, tan in dark.
    static let primary = dynamic(light: 0x343330, dark: 0xBE9967)
    static let primaryForeground = dynamic(light: 0xF3EDE0, dark: 0x1F1E1B)

    static let secondary = dynamic(light: 0xEAE2CE, dark: 0x2F2D2A)
    static let muted = dynamic(light: 0xEAE2CE, dark: 0x2F2D2A)
    static let mutedForeground = dynamic(light: 0x61615E, dark: 0xA09A8C)
    /// Hover / highlighted surfaces (`--accent`: tan in light, raised in dark).
    static let accent = dynamic(light: 0xBE9967, dark: 0x3A3732)

    static let destructive = dynamic(light: 0xB54A3C, dark: 0xC5584A)

    static let border = dynamic(light: 0xDDD2B8, dark: 0x3A3732)
    static let input = dynamic(light: 0xCFC3A8, dark: 0x3A3732)
    /// Focus ring and the app's accent colour (tan in both).
    static let ring = dynamic(light: 0xBE9967, dark: 0xBE9967)

    // Sidebar
    static let sidebar = dynamic(light: 0xFBF7EB, dark: 0x2A2825)
    static let sidebarAccent = dynamic(light: 0xEAE2CE, dark: 0x3A3732)

    /// The wordmark's orange (`--color-flame-500`).
    static let flame = Color(hex: 0xE8742C)

    /// The one "all good" colour: Wax's `--track` sage (Lossless).
    static let success = dynamic(light: 0x5C8A6A, dark: 0x7FB38E)

    // Timeline markers (`--track`, `--note`, `--spotlight`, `--marker` and
    // their `-surface` tints): what a chip or pin on the waveform is.
    static let track = success
    static let trackSurface = dynamic(light: 0xEAF1EB, dark: 0x1C2A23)
    static let note = dynamic(light: 0x7A6B99, dark: 0x9B8BC0)
    static let noteSurface = dynamic(light: 0xECE8F1, dark: 0x2A2535)
    static let spotlight = dynamic(light: 0xB05A7B, dark: 0xD47BA0)
    static let spotlightSurface = dynamic(light: 0xF4E3EA, dark: 0x35222A)
    static let marker = dynamic(light: 0xD4883A, dark: 0xE8A35A)
    static let markerSurface = dynamic(light: 0xFBF1DF, dark: 0x332618)
    /// Spots and Breaks: a Break sits outside the music, so it gets a colour
    /// of its own, apart from Tracks and notes.
    static let spot = dynamic(light: 0x3F7A99, dark: 0x6FA8C7)
    static let spotSurface = dynamic(light: 0xE4EEF3, dark: 0x1B2A33)

    /// Makes a colour that resolves per appearance (light / dark aqua).
    static func dynamic(light: UInt32, dark: UInt32) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            return NSColor(hex: isDark ? dark : light)
        })
    }
}

extension NSColor {
    convenience init(hex: UInt32, alpha: CGFloat = 1) {
        self.init(
            srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: alpha
        )
    }
}

extension Color {
    init(hex: UInt32) {
        self.init(nsColor: NSColor(hex: hex))
    }
}
