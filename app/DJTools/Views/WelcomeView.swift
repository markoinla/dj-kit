import SwiftUI

/// Nothing selected: one big drop target and what the three tools do.
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
        VStack(spacing: DJSpace.xl) {
            DJEmptyState(
                systemImage: "square.and.arrow.down",
                title: hasTracks ? "Drop more tracks, or pick one" : "Drop tracks here",
                message: "Or a folder of them. MP3, M4A, FLAC, WAV or AIFF. Each one gets a quality check as soon as it lands.",
                isTargeted: isTargeted
            ) {
                Button("Choose Files…", action: add)
                    .buttonStyle(.dj(.primary))
            }
            HStack(alignment: .top, spacing: DJSpace.md) {
                DJInfoCard(
                    systemImage: "waveform.badge.magnifyingglass",
                    title: "Check Quality",
                    message: "Spots low-bitrate rips and fake lossless files by where the highs stop."
                )
                DJInfoCard(
                    systemImage: "square.3.layers.3d",
                    title: "Separate Stems",
                    message: "Vocals, drums, bass and the rest as WAVs, ready for Rekordbox."
                )
                DJInfoCard(
                    systemImage: "wand.and.stars",
                    title: "Repair Audio",
                    message: "Rebuilds the top end of lossy files. Runs on this Mac."
                )
            }
            .fixedSize(horizontal: false, vertical: true)
        }
        .padding(DJSpace.xxxl)
        .frame(maxWidth: 760)
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
