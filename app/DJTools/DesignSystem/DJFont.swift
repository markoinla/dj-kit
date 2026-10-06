import AppKit
import CoreText
import SwiftUI

/// Manrope, Wax Studio's one typeface, shared so DJ Tools reads as its sibling.
///
/// The bundled file is a variable TTF (weight axis) in `Resources/Fonts`,
/// registered at launch through `ATSApplicationFontsPath`. Weights are set on the `wght` axis directly —
/// SwiftUI's `.fontWeight` doesn't reliably move a variable font's axis on
/// macOS. If the font is missing, the system font stands in.
enum DJFont {
    static let family = "Manrope"
    private static let fileName = "Manrope-VariableFont_wght"
    /// 'wght' as a four-char code.
    private static let weightAxis = 0x7767_6874

    /// Safety net for `ATSApplicationFontsPath` (e.g. SwiftUI previews).
    static func register() {
        guard !isAvailable,
              let url = Bundle.main.url(forResource: fileName, withExtension: "ttf") else { return }
        CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
    }

    static var isAvailable: Bool {
        NSFontManager.shared.availableFontFamilies.contains(family)
    }

    /// Manrope at `size` and `weight` (100…800), or the system font.
    static func nsFont(size: CGFloat, weight: CGFloat) -> NSFont {
        let descriptor = NSFontDescriptor(fontAttributes: [
            .family: family,
            NSFontDescriptor.AttributeName(rawValue: kCTFontVariationAttribute as String): [weightAxis: weight],
        ])
        if isAvailable, let font = NSFont(descriptor: descriptor, size: size) {
            return font
        }
        return NSFont.systemFont(ofSize: size, weight: systemWeight(weight))
    }

    private static func systemWeight(_ weight: CGFloat) -> NSFont.Weight {
        switch weight {
        case ..<450: .regular
        case ..<550: .medium
        case ..<650: .semibold
        case ..<750: .bold
        default: .heavy
        }
    }
}

/// The type scale. Web sizes are rem at a 17px root, which reads large on a
/// Mac; each step maps to the Mac size that plays the same role
/// (`text-sm` → 13, `text-xs` → 11, `text-2xl` → 22).
enum DJTextStyle: CaseIterable {
    /// Page titles ("DJ Tools", a track's name): `text-2xl font-bold tracking-tight`.
    case display
    /// The Set editor's title: `text-base font-semibold tracking-tight`.
    case title
    /// Card and banner headings ("We heard 12 tracks"): `font-semibold`.
    case headline
    /// Body copy: `text-sm`.
    case body
    /// Row titles: `text-sm font-medium`.
    case bodyMedium
    /// Helper text and row subtitles: `text-xs text-muted-foreground`.
    case caption
    /// Badges: `text-xs font-medium`.
    case captionMedium
    /// Section labels ("FILES"): `text-xs font-semibold uppercase tracking-wide`.
    case label

    var size: CGFloat {
        switch self {
        case .display: 22
        case .title: 15
        case .headline: 13
        case .body, .bodyMedium: 13
        case .caption, .captionMedium: 11
        case .label: 10
        }
    }

    var weight: CGFloat {
        switch self {
        case .display: 700
        case .title, .headline, .label: 600
        case .bodyMedium, .captionMedium: 500
        case .body, .caption: 400
        }
    }

    /// Letter spacing in points (`tracking-tight` = -0.02em, `tracking-wide` = 0.02em).
    var tracking: CGFloat {
        switch self {
        case .display: -0.02 * size
        case .title: -0.01 * size
        case .label: 0.06 * size
        default: 0
        }
    }

    var isUppercase: Bool { self == .label }

    var font: Font { Font(DJFont.nsFont(size: size, weight: weight)) }
}

extension View {
    /// Applies a step of the type scale (font, tracking, case).
    func djText(_ style: DJTextStyle) -> some View {
        font(style.font)
            .tracking(style.tracking)
            .textCase(style.isUppercase ? .uppercase : nil)
    }
}

extension Font {
    /// Manrope at an arbitrary size (for one-offs like the sign-in title).
    static func dj(_ size: CGFloat, weight: CGFloat = 400) -> Font {
        Font(DJFont.nsFont(size: size, weight: weight))
    }

    /// Row times ("1:02:45"): the web's `font-mono text-xs tabular-nums`.
    static let djMono = Font.system(size: 11, weight: .regular, design: .monospaced)
}
