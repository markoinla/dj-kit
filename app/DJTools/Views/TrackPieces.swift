import SwiftUI

// Small pieces shared by the sidebar, the detail pane and the queue.

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

/// A sidebar row: format tile, name, what's happening, the quality badge.
struct TrackRow: View {
    let track: Track
    let job: Job?

    var body: some View {
        HStack(spacing: 10) {
            FormatTile(container: track.container)
            VStack(alignment: .leading, spacing: 3) {
                Text(track.name)
                    .djText(.bodyMedium)
                    .foregroundStyle(DJColor.foreground)
                    .lineLimit(1)
                    .truncationMode(.middle)
                HStack(spacing: 4) {
                    Text(line)
                        .djText(.caption)
                        .foregroundStyle(isError ? DJColor.destructive : DJColor.mutedForeground)
                        .monospacedDigit()
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    if let verdict = track.verdict, job.map({ $0.kind.isHeavy || $0.kind.isDecoding }) != true {
                        QualityBadge(verdict: verdict)
                    }
                }
                if let job, job.kind.isHeavy || job.kind.isDecoding, job.state == .running {
                    DJProgressBar(fraction: job.progress, height: 3)
                        .padding(.top, 1)
                }
            }
        }
        .padding(.vertical, 3)
        .accessibilityElement(children: .combine)
    }

    private var isError: Bool {
        job == nil && (!track.fileExists || track.qualityError != nil)
    }

    private var line: String {
        if let job {
            switch (job.kind, job.state) {
            case (.quality, _): return "Checking…"
            case (_, .queued): return "Waiting"
            default: return job.statusLine
            }
        }
        if !track.fileExists { return "File missing" }
        if track.qualityError != nil { return "Couldn't check" }
        var parts = [track.container.uppercased()]
        if let quality = track.quality { parts.append(DJFormat.duration(quality.duration)) }
        // Only once measured (the Normalize row): measuring is a full decode.
        if let loudness = track.loudness, !loudness.isSilent { parts.append(DJFormat.lufs(loudness.integratedLUFS)) }
        if !track.results.isEmpty { parts.append(DJFormat.count(track.results.count, "result")) }
        return parts.joined(separator: " · ")
    }
}

/// A job: what, which track, its progress, and cancel / reveal / retry.
struct JobRow: View {
    let job: Job
    var showsTrack = true
    var cancel: () -> Void = {}
    var reveal: (URL) -> Void = { _ in }
    var retry: () -> Void = {}

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: job.kind.systemImage)
                .font(.system(size: 12))
                .foregroundStyle(iconTint)
                .frame(width: 18, height: 18)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(showsTrack ? job.trackName : job.kind.title)
                    .djText(.bodyMedium)
                    .foregroundStyle(DJColor.foreground)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(showsTrack ? "\(job.title) · \(job.statusLine)" : job.statusLine)
                    .djText(.caption)
                    .foregroundStyle(isFailed ? DJColor.destructive : DJColor.mutedForeground)
                    .monospacedDigit()
                    .lineLimit(isFailed ? 3 : 1)
                    .fixedSize(horizontal: false, vertical: true)
                if job.state == .running {
                    DJProgressBar(fraction: job.progress, height: 3)
                        .padding(.top, 2)
                }
            }
            Spacer(minLength: 4)
            HStack(spacing: 2) {
                if job.state.isActive {
                    DJIconButton(title: "Cancel", systemImage: "xmark", action: cancel)
                } else if let url = job.resultURL, job.state == .finished {
                    DJIconButton(title: "Reveal in Finder", systemImage: "magnifyingglass", tint: DJColor.foreground) { reveal(url) }
                } else if isFailed || job.state == .cancelled {
                    DJIconButton(title: "Try Again", systemImage: "arrow.clockwise", action: retry)
                }
            }
        }
        .padding(.vertical, 2)
    }

    private var isFailed: Bool {
        if case .failed = job.state { return true }
        return false
    }

    private var iconTint: Color {
        switch job.state {
        case .finished: DJColor.success
        case .failed: DJColor.destructive
        case .running: DJColor.foreground
        default: DJColor.mutedForeground
        }
    }
}
