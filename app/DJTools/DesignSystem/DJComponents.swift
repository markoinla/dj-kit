import AppKit
import SwiftUI

// Reusable pieces adapted from Wax Studio's `WaxComponents`, so DJ Tools
// reads as the same family: buttons, cards, section labels, the dashed drop
// zone, progress bars and notices.

// MARK: - Buttons

/// shadcn's `Button` variants: `primary`, `outline`, `ghost`, `destructive`,
/// plus `accent` (the tan ring colour) for the one suggested action.
struct DJButtonStyle: ButtonStyle {
    enum Variant { case primary, accent, outline, ghost, destructive }
    enum Size { case small, regular, large }

    var variant: Variant = .primary
    var size: Size = .regular
    var fullWidth = false

    func makeBody(configuration: Configuration) -> some View {
        DJButtonBody(configuration: configuration, variant: variant, size: size, fullWidth: fullWidth)
    }
}

private struct DJButtonBody: View {
    let configuration: ButtonStyleConfiguration
    let variant: DJButtonStyle.Variant
    let size: DJButtonStyle.Size
    let fullWidth: Bool
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.isFocused) private var isFocused
    @State private var isHovered = false

    var body: some View {
        configuration.label
            .labelStyle(DJButtonLabelStyle())
            .font(.dj(size == .small ? 12 : 13, weight: 500))
            .lineLimit(1)
            .padding(.horizontal, size == .small ? 10 : size == .large ? 18 : 14)
            .frame(maxWidth: fullWidth ? .infinity : nil)
            .frame(minHeight: size == .small ? 24 : size == .large ? 34 : 28)
            .foregroundStyle(foreground)
            .background(background, in: RoundedRectangle(cornerRadius: DJRadius.md))
            .overlay {
                if variant == .outline {
                    RoundedRectangle(cornerRadius: DJRadius.md).strokeBorder(DJColor.input)
                }
            }
            .overlay {
                if isFocused {
                    RoundedRectangle(cornerRadius: DJRadius.md + 2)
                        .strokeBorder(DJColor.ring.opacity(0.6), lineWidth: 3)
                        .padding(-3)
                }
            }
            .contentShape(RoundedRectangle(cornerRadius: DJRadius.md))
            .opacity(isEnabled ? 1 : 0.5)
            .onHover { isHovered = $0 }
    }

    private var foreground: Color {
        switch variant {
        case .primary: DJColor.primaryForeground
        case .accent: Color(hex: 0x1F1E1B)
        case .destructive: .white
        case .outline, .ghost: DJColor.foreground
        }
    }

    private var background: Color {
        let pressed = configuration.isPressed
        switch variant {
        case .primary:
            return DJColor.primary.opacity(pressed ? 0.8 : isHovered ? 0.9 : 1)
        case .accent:
            return DJColor.ring.opacity(pressed ? 0.8 : isHovered ? 0.9 : 1)
        case .destructive:
            return DJColor.destructive.opacity(pressed ? 0.8 : isHovered ? 0.9 : 1)
        case .outline:
            return pressed || isHovered ? DJColor.muted : DJColor.card
        case .ghost:
            return pressed || isHovered ? DJColor.muted : .clear
        }
    }
}

private struct DJButtonLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 6) {
            configuration.icon.imageScale(.small)
            configuration.title
        }
    }
}

extension ButtonStyle where Self == DJButtonStyle {
    static var djPrimary: DJButtonStyle { DJButtonStyle(variant: .primary) }
    static var djOutline: DJButtonStyle { DJButtonStyle(variant: .outline) }
    static func dj(_ variant: DJButtonStyle.Variant, size: DJButtonStyle.Size = .regular, fullWidth: Bool = false) -> DJButtonStyle {
        DJButtonStyle(variant: variant, size: size, fullWidth: fullWidth)
    }
}

/// A small icon-only button (cancel ✕, reveal ↗) drawn by SwiftUI, so it
/// shows the same in a window and in an offscreen render.
struct DJIconButton: View {
    let title: String
    let systemImage: String
    var tint: Color = DJColor.mutedForeground
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 20, height: 20)
                .background(isHovered ? DJColor.muted : .clear, in: RoundedRectangle(cornerRadius: DJRadius.sm))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .help(title)
        .accessibilityLabel(title)
    }
}

/// A text link in a section header or card ("Clear", "Check Again").
struct DJLinkButton: View {
    let title: String
    var tint: Color = DJColor.mutedForeground
    let action: () -> Void

    init(_ title: String, tint: Color = DJColor.mutedForeground, action: @escaping () -> Void) {
        self.title = title
        self.tint = tint
        self.action = action
    }

    var body: some View {
        Button(title, action: action)
            .buttonStyle(.plain)
            .font(.dj(11, weight: 500))
            .foregroundStyle(tint)
    }
}

// MARK: - Section header

/// A small label above a group ("QUALITY", "TRACKS 6") with an optional
/// helper line and trailing actions.
struct DJSectionHeader<Trailing: View>: View {
    let title: String
    var detail: String?
    var style: DJTextStyle = .label
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: DJSpace.sm) {
            Text(title)
                .djText(style)
                .foregroundStyle(style == .label ? DJColor.mutedForeground : DJColor.foreground)
            if let detail {
                Text(detail)
                    .djText(.caption)
                    .foregroundStyle(DJColor.mutedForeground)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 0)
            trailing
        }
        .accessibilityElement(children: .contain)
    }
}

extension DJSectionHeader where Trailing == EmptyView {
    init(_ title: String, detail: String? = nil, style: DJTextStyle = .label) {
        self.init(title: title, detail: detail, style: style) { EmptyView() }
    }
}

// MARK: - Empty state

/// The dashed drop zone (Wax's `WaxEmptyState`): an icon, one line saying
/// what to do, a helper line and actions.
struct DJEmptyState<Actions: View>: View {
    let systemImage: String
    let title: String
    let message: String
    var isTargeted = false
    @ViewBuilder var actions: Actions

    var body: some View {
        VStack(spacing: DJSpace.sm) {
            Image(systemName: systemImage)
                .font(.system(size: 26, weight: .regular))
                .foregroundStyle(DJColor.mutedForeground)
                .padding(.bottom, DJSpace.xs)
                .accessibilityHidden(true)
            Text(title)
                .font(.dj(19, weight: 600))
                .tracking(-0.3)
                .foregroundStyle(DJColor.foreground)
                .multilineTextAlignment(.center)
            Text(message)
                .djText(.body)
                .foregroundStyle(DJColor.mutedForeground)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: DJSpace.sm) { actions }
                .padding(.top, DJSpace.sm)
        }
        .padding(.horizontal, DJSpace.xxl)
        .padding(.vertical, 44)
        .frame(maxWidth: .infinity)
        .background(
            isTargeted ? DJColor.ring.opacity(0.08) : DJColor.muted.opacity(0.4),
            in: RoundedRectangle(cornerRadius: DJRadius.xl)
        )
        .overlay {
            RoundedRectangle(cornerRadius: DJRadius.xl)
                .strokeBorder(
                    isTargeted ? DJColor.ring : DJColor.mutedForeground.opacity(0.25),
                    style: StrokeStyle(lineWidth: 2, dash: [7, 5])
                )
        }
    }
}

/// A plain card (`rounded-xl border p-5`) — the welcome's three tools.
struct DJInfoCard: View {
    let systemImage: String
    let title: String
    let message: String

    var body: some View {
        HStack(alignment: .top, spacing: DJSpace.md) {
            Image(systemName: systemImage)
                .font(.system(size: 14))
                .foregroundStyle(DJColor.mutedForeground)
                .frame(width: 18)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: DJSpace.xs) {
                Text(title).djText(.headline).foregroundStyle(DJColor.foreground)
                Text(message)
                    .djText(.caption)
                    .foregroundStyle(DJColor.mutedForeground)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(DJSpace.lg)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .overlay(RoundedRectangle(cornerRadius: DJRadius.xl).strokeBorder(DJColor.border))
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Progress

/// Wax's thin bar (`h-1.5 rounded-full`). `nil` is indeterminate: a third of
/// the track sliding back and forth.
struct DJProgressBar: View {
    var fraction: Double?
    var height: CGFloat = 4
    var tint: Color = DJColor.foreground.opacity(0.7)
    @State private var phase = false

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule().fill(DJColor.foreground.opacity(0.08))
                if let fraction {
                    Capsule()
                        .fill(tint)
                        .frame(width: max(height, geometry.size.width * min(max(fraction, 0), 1)))
                        .animation(.linear(duration: 0.2), value: fraction)
                } else {
                    Capsule()
                        .fill(tint.opacity(0.7))
                        .frame(width: geometry.size.width / 3)
                        .offset(x: phase ? geometry.size.width * 2 / 3 : 0)
                        .animation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true), value: phase)
                        .onAppear { phase = true }
                }
            }
        }
        .frame(height: height)
        .accessibilityElement()
        .accessibilityValue(fraction.map(DJFormat.percent) ?? "In progress")
    }
}

// MARK: - Surfaces

extension View {
    /// `rounded-lg border border-border/70` on the card colour.
    func djCard(padding: CGFloat = 0, radius: CGFloat = DJRadius.lg) -> some View {
        self.padding(padding)
            .background(DJColor.card, in: RoundedRectangle(cornerRadius: radius))
            .overlay(RoundedRectangle(cornerRadius: radius).strokeBorder(DJColor.border.opacity(0.8)))
    }

    /// `rounded-xl bg-muted/50` — trays and banners.
    func djTray(padding: CGFloat = DJSpace.md) -> some View {
        self.padding(padding)
            .background(DJColor.muted.opacity(0.5), in: RoundedRectangle(cornerRadius: DJRadius.xl))
    }
}

/// The hairline between rows in a `djCard`.
struct DJDivider: View {
    var body: some View {
        Rectangle().fill(DJColor.border.opacity(0.6)).frame(height: 1)
    }
}

/// A vertical hairline (between stat columns).
struct DJVerticalDivider: View {
    var body: some View {
        Rectangle().fill(DJColor.border.opacity(0.6)).frame(width: 1)
    }
}

// MARK: - Notices

/// The inline strip (Wax's `WaxNotice`): destructive for errors, amber for
/// something degraded, muted for information.
struct DJNotice: View {
    enum Kind { case error, warning, info }
    let kind: Kind
    let message: String
    var dismiss: (() -> Void)?

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: DJSpace.sm) {
            Image(systemName: icon)
                .foregroundStyle(tint)
                .accessibilityHidden(true)
            Text(message)
                .djText(.body)
                .foregroundStyle(DJColor.foreground)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            if let dismiss {
                DJIconButton(title: "Dismiss", systemImage: "xmark", action: dismiss)
            }
        }
        .padding(.horizontal, DJSpace.md)
        .padding(.vertical, DJSpace.sm)
        .background(tint.opacity(0.1), in: RoundedRectangle(cornerRadius: DJRadius.lg))
    }

    private var icon: String {
        switch kind {
        case .error: "exclamationmark.triangle.fill"
        case .warning: "exclamationmark.circle.fill"
        case .info: "info.circle"
        }
    }

    private var tint: Color {
        switch kind {
        case .error: DJColor.destructive
        case .warning: DJColor.marker
        case .info: DJColor.mutedForeground
        }
    }
}

// MARK: - Segmented control

/// A Wax-styled segmented picker: options in a muted track, the chosen one
/// raised on the card colour. Drawn by SwiftUI (not `NSSegmentedControl`).
struct DJSegmented<Value: Hashable>: View {
    let options: [Value]
    @Binding var selection: Value
    let label: (Value) -> String

    var body: some View {
        HStack(spacing: 2) {
            ForEach(options, id: \.self) { option in
                let isSelected = option == selection
                Button { selection = option } label: {
                    Text(label(option))
                        .font(.dj(12, weight: isSelected ? 600 : 500))
                        .foregroundStyle(isSelected ? DJColor.foreground : DJColor.mutedForeground)
                        .lineLimit(1)
                        .frame(maxWidth: .infinity)
                        .frame(height: 24)
                        .background {
                            if isSelected {
                                RoundedRectangle(cornerRadius: DJRadius.sm + 1)
                                    .fill(DJColor.card)
                                    .shadow(color: .black.opacity(0.08), radius: 1, y: 1)
                            }
                        }
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(isSelected ? .isSelected : [])
            }
        }
        .padding(2)
        .background(DJColor.muted, in: RoundedRectangle(cornerRadius: DJRadius.md))
    }
}

// MARK: - Window chrome (macOS 15 APIs, with macOS 14 stand-ins)

extension View {
    func hiddenToolbarBackground() -> some View {
        if #available(macOS 15.0, *) {
            return toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
        } else {
            return toolbarBackground(.hidden, for: .windowToolbar)
        }
    }

    @ViewBuilder
    func hidingWindowTitle() -> some View {
        if #available(macOS 15.0, *) {
            toolbar(removing: .title)
        } else {
            navigationTitle("")
        }
    }

    @ViewBuilder
    func windowBackground(_ color: Color) -> some View {
        if #available(macOS 15.0, *) {
            containerBackground(color, for: .window)
        } else {
            background(color.ignoresSafeArea())
        }
    }
}

// MARK: - Formatting

enum DJFormat {
    /// "40%".
    static func percent(_ fraction: Double) -> String {
        "\(Int((min(max(fraction, 0), 1) * 100).rounded()))%"
    }

    /// "1 track" / "12 tracks".
    static func count(_ n: Int, _ noun: String) -> String {
        "\(n) \(noun)\(n == 1 ? "" : "s")"
    }

    /// "6:12" / "1:02:45".
    static func duration(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded())
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }

    /// "16.0 kHz" / "44.1 kHz".
    static func kHz(_ hz: Double) -> String {
        String(format: "%.1f kHz", hz / 1000)
    }

    /// "48.2 MB".
    static func bytes(_ n: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: n, countStyle: .file)
    }

    /// "Stereo" / "Mono" / "6 channels".
    static func channels(_ n: Int) -> String {
        switch n {
        case 1: "Mono"
        case 2: "Stereo"
        default: "\(n) channels"
        }
    }

    /// "−6.2" / "+3.8" / "0.0": a typographic minus, "+" only with `plus`.
    static func signed(_ value: Double, decimals: Int = 1, plus: Bool = false) -> String {
        guard value.isFinite else { return value < 0 ? "−∞" : "∞" }
        let text = String(format: "%.\(decimals)f", abs(value))
        let isZero = Double(text) == 0
        if value < 0, !isZero { return "−" + text }
        return plus && !isZero ? "+" + text : text
    }

    /// "−6.2 LUFS"; `decimals: 0` for targets ("−10 LUFS").
    static func lufs(_ value: Double, decimals: Int = 1) -> String {
        value.isFinite ? "\(signed(value, decimals: decimals)) LUFS" : "Silent"
    }

    /// "−0.3 dBTP", "+0.4 dBTP" (over full scale gets its sign).
    static func dBTP(_ value: Double) -> String {
        "\(signed(value, plus: true)) dBTP"
    }

    /// A gain change: "+3.8 dB", "−1.5 dB", "0.0 dB".
    static func gain(_ dB: Double) -> String {
        "\(signed(dB, plus: true)) dB"
    }

    /// A path with the home folder as "~".
    static func path(_ url: URL) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let path = url.path
        return path.hasPrefix(home) ? "~" + path.dropFirst(home.count) : path
    }
}
