import SwiftUI

// Small pieces shared by the sidebar and the detail pane.

extension DJQualityVerdict {
    /// The badge dot: sage for lossless, quiet for good, amber for low,
    /// red for fake. Colour only where there's something to act on.
    var tint: Color {
        switch self {
        case .lossless: DJColor.success
        case .goodLossy: DJColor.mutedForeground
        case .lowQuality: DJColor.marker
        case .fakeLossless: DJColor.destructive
        case .unknown: DJColor.mutedForeground.opacity(0.6)
        }
    }

    var surface: Color {
        switch self {
        case .lossless: DJColor.trackSurface
        case .goodLossy, .unknown: DJColor.muted
        case .lowQuality: DJColor.markerSurface
        case .fakeLossless: DJColor.destructive.opacity(0.12)
        }
    }

    var systemImage: String {
        switch self {
        case .lossless: "checkmark.seal.fill"
        case .goodLossy: "checkmark.circle.fill"
        case .lowQuality: "exclamationmark.triangle.fill"
        case .fakeLossless: "xmark.octagon.fill"
        case .unknown: "questionmark.circle"
        }
    }
}

/// "● Lossless" — a track's quality verdict as a pill.
struct QualityBadge: View {
    let verdict: DJQualityVerdict
    var large = false

    var body: some View {
        HStack(spacing: large ? 6 : 5) {
            Circle().fill(verdict.tint).frame(width: large ? 7 : 6, height: large ? 7 : 6)
            Text(verdict.label)
        }
        .font(.dj(large ? 12 : 11, weight: large ? 600 : 500))
        .foregroundStyle(verdict == .goodLossy || verdict == .unknown ? DJColor.mutedForeground : DJColor.foreground)
        .lineLimit(1)
        .fixedSize()
        .padding(.horizontal, large ? 10 : 8)
        .padding(.vertical, large ? 4 : 2)
        .background(Capsule().fill(verdict.surface))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Quality: \(verdict.label)")
    }
}

/// The square in place of artwork: the file's format ("FLAC") on muted.
struct FormatTile: View {
    let container: String
    var size: CGFloat = DJSize.sidebarTile

    var body: some View {
        ZStack {
            DJColor.muted
            VStack(spacing: size > 40 ? 3 : 1) {
                Image(systemName: "waveform")
                    .font(.system(size: size * 0.3, weight: .medium))
                    .foregroundStyle(DJColor.mutedForeground.opacity(0.7))
                Text(label)
                    .font(.system(size: max(7, size * 0.2), weight: .semibold, design: .monospaced))
                    .foregroundStyle(DJColor.mutedForeground)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
            }
            .padding(.horizontal, 2)
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: size > 40 ? DJRadius.lg : DJRadius.sm))
        .overlay {
            RoundedRectangle(cornerRadius: size > 40 ? DJRadius.lg : DJRadius.sm)
                .strokeBorder(DJColor.border.opacity(0.6))
        }
        .accessibilityHidden(true)
    }

    private var label: String {
        switch container {
        case "aif": "AIFF"
        default: container.uppercased()
        }
    }
}

/// A sidebar row: format tile, the name (a dot after it when the file
/// sounds lossy), one status line, and a thin bar while it's processed.
struct TrackRow: View {
    let track: Track
    let stage: TrackStage
    /// The track's latest Process run.
    let job: Job?
    var isChecking = false

    var body: some View {
        HStack(spacing: 10) {
            FormatTile(container: track.container)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(track.name)
                        .djText(.bodyMedium)
                        .foregroundStyle(DJColor.foreground)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if let verdict = track.verdict, track.needsRepair {
                        Circle().fill(verdict.tint).frame(width: 6, height: 6)
                            .help(verdict.label)
                    }
                }
                Text(line)
                    .djText(.caption)
                    .foregroundStyle(isError ? DJColor.destructive : DJColor.mutedForeground)
                    .monospacedDigit()
                    .lineLimit(1)
                if stage == .processing, let job, job.state == .running {
                    DJProgressBar(fraction: job.progress, height: 3, tint: DJColor.ring)
                        .padding(.top, 2)
                }
            }
        }
        .padding(.vertical, 3)
        .accessibilityElement(children: .combine)
    }

    private var failed: Bool {
        if case .failed = job?.state { return true }
        return false
    }

    private var isError: Bool {
        stage == .ready && (failed || !track.fileExists || (!isChecking && track.qualityError != nil))
    }

    private var line: String {
        switch stage {
        case .processing:
            guard let job, job.state == .running else { return "Waiting" }
            return job.currentStep?.verb ?? "Starting"
        case .done:
            guard let files = track.latestFiles else { return "" }
            var parts: [String] = []
            if let url = files.output ?? files.stems?.values.first { parts.append(DJFormat.container(url.pathExtension)) }
            if let plan = files.normalization { parts.append(DJFormat.lufs(plan.resultingLUFS)) }
            if let stems = files.stems, !stems.isEmpty { parts.append(DJFormat.count(stems.count, "stem")) }
            return parts.joined(separator: " · ")
        case .ready:
            if failed { return "Failed" }
            if !track.fileExists { return "File missing" }
            if isChecking { return "Checking…" }
            if track.qualityError != nil { return "Couldn't check" }
            return [DJFormat.container(track.container), track.quality.map { DJFormat.duration($0.duration) }]
                .compactMap { $0 }.joined(separator: " · ")
        }
    }
}
