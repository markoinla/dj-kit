import AppKit
import AudioExport
import SwiftUI

/// The detail pane for the sidebar's selection: one track, or several.
struct TrackDetailView: View {
    let ids: [Track.ID]

    var body: some View {
        ScrollView {
            TrackDetailContent(ids: ids)
                .frame(maxWidth: .infinity)
        }
    }
}

/// The detail without its scroll view (also drawn by `-renderPreviews`).
struct TrackDetailContent: View {
    @Environment(AppModel.self) private var model
    let ids: [Track.ID]

    var body: some View {
        let tracks = ids.compactMap(model.track)
        VStack(alignment: .leading, spacing: DJSpace.xxl) {
            if tracks.count == 1, let track = tracks.first {
                TrackHeader(track: track)
                if !track.fileExists {
                    DJNotice(kind: .warning, message: "File not found. Drop it in again.")
                }
                ProcessCard(ids: ids, initial: model.settings.lastRecipe)
                if !track.results.isEmpty {
                    ResultsSection(track: track, outputFolder: model.settings.outputFolder)
                }
                TrackIDSection(track: track, job: model.job(for: track.id, kind: .identify))
                QualitySection(track: track, job: model.job(for: track.id, kind: .quality))
            } else {
                SelectionHeader(tracks: tracks)
                ProcessCard(ids: ids, initial: model.settings.lastRecipe)
            }
        }
        .padding(.horizontal, DJSpace.xxxl)
        .padding(.top, DJSpace.lg)
        .padding(.bottom, DJSpace.xxxl)
        .frame(maxWidth: DJSize.detailMaxWidth, alignment: .leading)
    }
}

// MARK: - Header

private struct TrackHeader: View {
    let track: Track

    var body: some View {
        HStack(alignment: .center, spacing: DJSpace.lg) {
            FormatTile(container: track.container, size: DJSize.headerTile)
            VStack(alignment: .leading, spacing: 4) {
                Text(track.name)
                    .djText(.display)
                    .foregroundStyle(DJColor.foreground)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                Text(DJFormat.path(track.url.deletingLastPathComponent()))
                    .djText(.caption)
                    .foregroundStyle(DJColor.mutedForeground)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: DJSpace.md)
            Button("Reveal in Finder", systemImage: "folder") {
                NSWorkspace.shared.activateFileViewerSelecting([track.url])
            }
            .buttonStyle(.dj(.outline, size: .small))
            .disabled(!track.fileExists)
        }
    }
}

private struct SelectionHeader: View {
    @Environment(AppModel.self) private var model
    let tracks: [Track]

    var body: some View {
        VStack(alignment: .leading, spacing: DJSpace.md) {
            VStack(alignment: .leading, spacing: 4) {
                Text("\(tracks.count) tracks selected")
                    .djText(.display)
                    .foregroundStyle(DJColor.foreground)
                Text(breakdown)
                    .djText(.body)
                    .foregroundStyle(DJColor.mutedForeground)
            }
            let pending = tracks.filter(\.hasPendingIdentity)
            if !pending.isEmpty {
                HStack(spacing: DJSpace.md) {
                    Image(systemName: "shazam.logo").foregroundStyle(DJColor.ring)
                    Text("\(DJFormat.count(pending.count, "Track ID match")) to apply")
                        .djText(.body)
                        .foregroundStyle(DJColor.foreground)
                    Spacer(minLength: DJSpace.md)
                    Button("Apply \(pending.count)", systemImage: "checkmark") { model.applyIdentity(pending.map(\.id)) }
                        .buttonStyle(.dj(.primary, size: .small))
                        .disabled(pending.allSatisfy { model.applying.contains($0.id) })
                }
                .djCard(padding: DJSpace.md)
            }
            VStack(spacing: 0) {
                ForEach(Array(tracks.prefix(8).enumerated()), id: \.element.id) { index, track in
                    if index > 0 { DJDivider() }
                    HStack(spacing: DJSpace.md) {
                        FormatTile(container: track.container, size: 24)
                        Text(track.name)
                            .djText(.body)
                            .foregroundStyle(DJColor.foreground)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer(minLength: DJSpace.md)
                        if let verdict = track.verdict {
                            QualityBadge(verdict: verdict)
                        } else {
                            Text("Checking…").djText(.caption).foregroundStyle(DJColor.mutedForeground)
                        }
                    }
                    .padding(.horizontal, DJSpace.md)
                    .padding(.vertical, 7)
                }
                if tracks.count > 8 {
                    DJDivider()
                    Text("and \(tracks.count - 8) more")
                        .djText(.caption)
                        .foregroundStyle(DJColor.mutedForeground)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, DJSpace.md)
                        .padding(.vertical, 7)
                }
            }
            .djCard()
        }
    }

    /// "2 low quality · 1 fake lossless · 2 lossless".
    private var breakdown: String {
        let order: [DJQualityVerdict] = [.fakeLossless, .lowQuality, .goodLossy, .lossless, .unknown]
        var parts = order.compactMap { verdict -> String? in
            let n = tracks.filter { $0.verdict == verdict }.count
            return n > 0 ? "\(n) \(verdict.label.lowercased())" : nil
        }
        let unchecked = tracks.filter { $0.verdict == nil }.count
        if unchecked > 0 { parts.append("\(unchecked) checking") }
        return parts.joined(separator: " · ")
    }
}

// MARK: - Quality

private struct QualitySection: View {
    @Environment(AppModel.self) private var model
    let track: Track
    let job: Job?

    var body: some View {
        VStack(alignment: .leading, spacing: DJSpace.sm) {
            DJSectionHeader(title: "Quality") {
                if job?.state.isActive != true, track.fileExists {
                    DJLinkButton("Check Again") { model.checkQuality([track.id]) }
                }
            }
            content
        }
    }

    @ViewBuilder private var content: some View {
        if job?.state.isActive == true {
            VStack(alignment: .leading, spacing: DJSpace.sm) {
                Text("Checking…").djText(.bodyMedium).foregroundStyle(DJColor.foreground)
                DJProgressBar(fraction: nil, height: 4)
                    .frame(maxWidth: 240)
                    .padding(.top, 2)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .djCard(padding: DJSpace.lg)
        } else if let report = track.quality {
            QualityCard(report: report, fileSize: track.fileSize)
        } else if let error = track.qualityError {
            DJNotice(kind: .error, message: "Couldn't check: \(error)")
        } else {
            Text("Not checked yet.")
                .djText(.body)
                .foregroundStyle(DJColor.mutedForeground)
                .frame(maxWidth: .infinity, alignment: .leading)
                .djCard(padding: DJSpace.lg)
        }
    }
}

struct QualityCard: View {
    let report: DJQualityReport
    var fileSize: Int64?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: DJSpace.md) {
                Image(systemName: report.verdict.systemImage)
                    .font(.system(size: 18))
                    .foregroundStyle(report.verdict.tint)
                    .frame(width: 22)
                    .accessibilityHidden(true)
                HStack(spacing: DJSpace.sm) {
                    Text(report.summary)
                        .djText(.headline)
                        .foregroundStyle(DJColor.foreground)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: DJSpace.sm)
                    QualityBadge(verdict: report.verdict, large: true)
                }
            }
            .padding(DJSpace.lg)

            if let cutoff = report.cutoffHz {
                CutoffMeter(cutoffHz: cutoff, nyquist: report.sampleRate / 2, verdict: report.verdict)
                    .padding(.horizontal, DJSpace.lg)
                    .padding(.bottom, DJSpace.lg)
            }

            DJDivider()
            HStack(spacing: 0) {
                fact("Format", formatLabel)
                DJVerticalDivider()
                fact("Bitrate", report.declaredBitrateKbps.map { "\($0) kbps" } ?? "—")
                DJVerticalDivider()
                fact("Sample rate", DJFormat.kHz(report.sampleRate))
                DJVerticalDivider()
                fact("Channels", DJFormat.channels(report.channels))
                DJVerticalDivider()
                fact("Length", DJFormat.duration(report.duration))
                if let fileSize {
                    DJVerticalDivider()
                    fact("Size", DJFormat.bytes(fileSize))
                }
            }
            .fixedSize(horizontal: false, vertical: true)
        }
        .djCard()
    }

    private var formatLabel: String {
        let name = report.container == "aif" ? "AIFF" : report.container.uppercased()
        return report.isLosslessContainer ? "\(name) · lossless" : name
    }

    private func fact(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).djText(.caption).foregroundStyle(DJColor.mutedForeground).lineLimit(1)
            Text(value)
                .font(.dj(13, weight: 600))
                .monospacedDigit()
                .foregroundStyle(DJColor.foreground)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}

/// Where the highs stop, on a 0…Nyquist scale with the usual MP3 lowpass
/// points marked (16 kHz ≈ 128 kbps, 19–20 kHz ≈ 256–320 kbps).
struct CutoffMeter: View {
    let cutoffHz: Double
    let nyquist: Double
    let verdict: DJQualityVerdict

    /// Typical MP3 lowpass points (16 kHz ≈ 128 kbps, 20 kHz ≈ 320 kbps).
    private let marks: [(Double, String)] = [(16_000, "128 kbps"), (20_000, "320 kbps")]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text("Spectral cutoff")
                    .djText(.caption)
                    .foregroundStyle(DJColor.mutedForeground)
                Spacer()
                Text(DJFormat.kHz(cutoffHz))
                    .font(.dj(12, weight: 600))
                    .monospacedDigit()
                    .foregroundStyle(DJColor.foreground)
                Text("of \(DJFormat.kHz(nyquist))")
                    .djText(.caption)
                    .monospacedDigit()
                    .foregroundStyle(DJColor.mutedForeground)
            }
            GeometryReader { geometry in
                let width = geometry.size.width
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 3)
                        .fill(DJColor.foreground.opacity(0.06))
                    RoundedRectangle(cornerRadius: 3)
                        .fill(LinearGradient(
                            colors: [verdict.tint.opacity(0.35), verdict.tint.opacity(0.85)],
                            startPoint: .leading, endPoint: .trailing
                        ))
                        .frame(width: width * fraction(cutoffHz))
                    ForEach(marks, id: \.0) { mark in
                        Rectangle()
                            .fill(DJColor.foreground.opacity(0.25))
                            .frame(width: 1)
                            .offset(x: width * fraction(mark.0))
                    }
                }
            }
            .frame(height: 10)
            GeometryReader { geometry in
                let width = geometry.size.width
                ZStack(alignment: .topLeading) {
                    Text("0").offset(x: 0)
                    ForEach(marks, id: \.0) { mark in
                        Text(mark.1)
                            .fixedSize()
                            .frame(width: 60)
                            .offset(x: width * fraction(mark.0) - 30)
                    }
                }
                .font(.system(size: 9, weight: .medium, design: .monospaced))
                .foregroundStyle(DJColor.mutedForeground.opacity(0.8))
            }
            .frame(height: 11)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Spectral cutoff \(DJFormat.kHz(cutoffHz))")
    }

    private func fraction(_ hz: Double) -> Double {
        guard nyquist > 0 else { return 0 }
        return min(max(hz / nyquist, 0), 1)
    }
}

// MARK: - Results

private struct ResultsSection: View {
    let track: Track
    let outputFolder: URL

    var body: some View {
        VStack(alignment: .leading, spacing: DJSpace.sm) {
            DJSectionHeader("Results", detail: "In \(DJFormat.path(outputFolder))")
            VStack(spacing: 0) {
                ForEach(Array(track.results.reversed().enumerated()), id: \.element.id) { index, result in
                    if index > 0 { DJDivider() }
                    ResultRow(result: result)
                }
            }
            .djCard()
        }
    }
}

private struct ResultRow: View {
    let result: TrackResult

    var body: some View {
        HStack(alignment: .center, spacing: DJSpace.md) {
            Image(systemName: icon)
                .font(.system(size: 13))
                .foregroundStyle(DJColor.mutedForeground)
                .frame(width: 20)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: DJSpace.sm) {
                    Text(title).djText(.bodyMedium).foregroundStyle(DJColor.foreground)
                    Text(result.finishedAt.formatted(.relative(presentation: .named)))
                        .djText(.caption)
                        .foregroundStyle(DJColor.mutedForeground)
                }
                switch result.kind {
                case .processed(let files):
                    HStack(spacing: 4) {
                        ForEach(chips(files), id: \.self) { chip in
                            Text(chip)
                                .font(.dj(11, weight: 500))
                                .monospacedDigit()
                                .foregroundStyle(DJColor.foreground)
                                .padding(.horizontal, 7)
                                .padding(.vertical, 1)
                                .background(Capsule().fill(DJColor.muted))
                        }
                    }
                case .stems(let model, _, let stems):
                    HStack(spacing: 4) {
                        ForEach((model.stemNames + [DJStemChoice.instrumental]).filter { stems[$0] != nil }, id: \.self) { name in
                            Text(name)
                                .font(.dj(11, weight: 500))
                                .foregroundStyle(DJColor.foreground)
                                .padding(.horizontal, 7)
                                .padding(.vertical, 1)
                                .background(Capsule().fill(DJColor.muted))
                        }
                    }
                case .repaired(let output, let plan):
                    Text([output.lastPathComponent, plan.map { "normalized to \(DJFormat.lufs($0.resultingLUFS))" }]
                        .compactMap { $0 }.joined(separator: " · "))
                        .djText(.caption)
                        .foregroundStyle(DJColor.mutedForeground)
                        .lineLimit(1)
                        .truncationMode(.middle)
                case .normalized(let output, let plan):
                    Text("\(plan.change) · \(output.lastPathComponent)")
                        .djText(.caption)
                        .foregroundStyle(DJColor.mutedForeground)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            Spacer(minLength: DJSpace.md)
            Button("Reveal in Finder", systemImage: "magnifyingglass") {
                NSWorkspace.shared.activateFileViewerSelecting([result.revealURL])
            }
            .buttonStyle(.dj(.ghost, size: .small))
            .disabled(!FileCheck.exists(result.revealURL))
        }
        .padding(.horizontal, DJSpace.md)
        .padding(.vertical, 10)
    }

    /// "Repaired", "−10.0 LUFS", "4 stems".
    private func chips(_ files: ProcessedFiles) -> [String] {
        var chips: [String] = []
        if files.repaired { chips.append("Repaired") }
        if let plan = files.normalization { chips.append(DJFormat.lufs(plan.resultingLUFS)) }
        if let stems = files.stems { chips.append(DJFormat.count(stems.count, "stem")) }
        return chips
    }

    private var icon: String {
        switch result.kind {
        case .processed(let files): files.output == nil ? "square.3.layers.3d" : "waveform"
        case .stems: "square.3.layers.3d"
        case .repaired: "wand.and.stars"
        case .normalized: "speaker.wave.2"
        }
    }

    private var title: String {
        switch result.kind {
        case .processed(let files): (files.output ?? files.stemsFolder)?.lastPathComponent ?? "Processed"
        case .stems(let model, _, _): "Stems · \(model.modelName)"
        case .repaired: "Repaired"
        case .normalized: "Normalized"
        }
    }
}

// MARK: - Loudness

extension DJNormalizationPlan {
    /// "−6.2 → −10.0 LUFS, −3.8 dB" for a results row.
    var change: String {
        let from = resultingLUFS - gainDB
        return "\(DJFormat.signed(from)) → \(DJFormat.lufs(resultingLUFS)), \(DJFormat.gain(gainDB))"
    }
}
