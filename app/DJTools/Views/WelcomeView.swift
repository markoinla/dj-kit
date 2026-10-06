import SwiftUI

/// Nothing selected: one big drop target and the steps a track goes through.
struct WelcomeView: View {
    var isTargeted: Bool
    var hasTracks = false
    var add: () -> Void

    var body: some View {
        GeometryReader { proxy in
            ScrollView {
                WelcomeContent(isTargeted: isTargeted, hasTracks: hasTracks, add: add)
                    .frame(maxWidth: .infinity, minHeight: proxy.size.height)
            }
        }
    }
}

/// The welcome without its scroll view (also drawn by `-renderPreviews`).
struct WelcomeContent: View {
    var isTargeted: Bool
    var hasTracks = false
    var add: () -> Void

    var body: some View {
        VStack(spacing: DJSpace.lg) {
            DJEmptyState(
                systemImage: "square.and.arrow.down",
                title: hasTracks ? "Drop more tracks, or pick one" : "Drop tracks here",
                message: "MP3, M4A, FLAC, WAV, AIFF",
                isTargeted: isTargeted
            ) {
                Button("Choose Files…", action: add)
                    .buttonStyle(.dj(.primary))
            }
            HStack(spacing: DJSpace.sm) {
                step("waveform.badge.magnifyingglass", "Analyze")
                arrow
                step("wand.and.stars", "Repair")
                arrow
                step("speaker.wave.2", "Normalize")
                arrow
                step("square.3.layers.3d", "Stems")
            }
            .djText(.caption)
            .foregroundStyle(DJColor.mutedForeground)
        }
        .padding(DJSpace.xxxl)
        .frame(maxWidth: 640)
    }

    private func step(_ systemImage: String, _ title: String) -> some View {
        Label(title, systemImage: systemImage)
    }

    private var arrow: some View {
        Image(systemName: "arrow.right")
            .font(.system(size: 9, weight: .semibold))
            .foregroundStyle(DJColor.mutedForeground.opacity(0.6))
            .accessibilityHidden(true)
    }
}

/// The whole-window "drop to add" highlight.
struct DropOverlay: View {
    var body: some View {
        RoundedRectangle(cornerRadius: DJRadius.xl)
            .strokeBorder(DJColor.ring, style: StrokeStyle(lineWidth: 3, dash: [9, 6]))
            .background(DJColor.ring.opacity(0.06), in: RoundedRectangle(cornerRadius: DJRadius.xl))
            .overlay {
                Label("Drop to add tracks", systemImage: "plus.circle.fill")
                    .font(.dj(15, weight: 600))
                    .foregroundStyle(DJColor.primaryForeground)
                    .padding(.horizontal, DJSpace.lg)
                    .padding(.vertical, DJSpace.sm)
                    .background(DJColor.primary, in: Capsule())
            }
            .padding(DJSpace.sm)
            .allowsHitTesting(false)
    }
}
