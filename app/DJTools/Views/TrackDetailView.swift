import AppKit
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
    /// The picker's choice; Settings' default until changed.
    @State private var stemModel: DJStemModel?

    var body: some View {
        let tracks = ids.compactMap(model.track)
        VStack(alignment: .leading, spacing: DJSpace.xxl) {
            if tracks.count == 1, let track = tracks.first {
                TrackHeader(track: track)
                if !track.fileExists {
                    DJNotice(kind: .warning, message: "Can't find this file any more. It may have been moved or renamed; drop it in again to keep working on it.")
                }
                QualitySection(track: track, job: model.job(for: track.id, kind: .quality))
            } else {
                SelectionHeader(tracks: tracks)
            }
            toolsSection(tracks)
            if tracks.count == 1, let track = tracks.first, !track.results.isEmpty {
                ResultsSection(track: track, outputFolder: model.settings.outputFolder)
            }
        }
        .padding(.horizontal, DJSpace.xxxl)
        .padding(.top, DJSpace.lg)
        .padding(.bottom, DJSpace.xxxl)
        .frame(maxWidth: DJSize.detailMaxWidth, alignment: .leading)
    }

    private func toolsSection(_ tracks: [Track]) -> some View {
        let ids = tracks.map(\.id)
        let chosen = stemModel ?? model.settings.defaultStemModel
        let lowCount = tracks.filter(\.needsRepair).count
        return VStack(alignment: .leading, spacing: DJSpace.sm) {
            DJSectionHeader("Tools", detail: tracks.count > 1 ? "Runs on all \(tracks.count) selected" : nil)
            HStack(alignment: .top, spacing: DJSpace.md) {
                ToolCard(
                    systemImage: "square.3.layers.3d",
                    title: "Separate Stems",
                    message: "Writes each stem as a WAV in a “(Stems)” folder. A few minutes a track.",
                    jobs: tracks.compactMap { model.job(for: $0.id, kind: .stems(chosen)) },
                    multi: tracks.count > 1
                ) {
                    VStack(alignment: .leading, spacing: 6) {
                        DJSegmented(options: DJStemModel.allCases, selection: Binding(
                            get: { chosen }, set: { stemModel = $0 }
                        )) { $0.title }
                        Text("\(chosen.modelName) — \(chosen.helper)")
                            .djText(.caption)
                            .foregroundStyle(DJColor.mutedForeground)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                } action: {
                    Button(tracks.count > 1 ? "Separate \(tracks.count) Tracks" : "Separate Stems", systemImage: "play.fill") {
                        model.separateStems(ids, model: chosen)
                    }
                    // The suggested repair gets the strong button.
                    .buttonStyle(.dj(lowCount > 0 ? .outline : .primary, fullWidth: true))
                    .disabled(allBusy(ids, kind: .stems(chosen)))
                }

                ToolCard(
                    systemImage: "wand.and.stars",
                    title: "Repair with Apollo",
                    message: "Rebuilds the high end that lossy encoding cut off and writes a new WAV. The original stays as it is. Takes about as long as the track: a 4-minute track is about 4 minutes on an M-series MacBook Air.",
                    jobs: tracks.compactMap { model.job(for: $0.id, kind: .repair) },
                    multi: tracks.count > 1,
                    suggestion: suggestion(tracks: tracks, lowCount: lowCount)
                ) {
                    VStack(alignment: .leading, spacing: 6) {
                        if model.apolloState != .ready {
                            Label("First use downloads the repair engine, about 600 MB.", systemImage: "arrow.down.circle")
                                .djText(.caption)
                                .foregroundStyle(DJColor.mutedForeground)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        if let note = lowSourceNote(tracks) {
                            Label(note, systemImage: "ear")
                                .djText(.caption)
                                .foregroundStyle(DJColor.mutedForeground)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                } action: {
                    Button(repairTitle(tracks: tracks, lowCount: lowCount), systemImage: "wand.and.stars") {
                        // Several selected: repair the ones that need it, or all if none do.
                        let targets = lowCount > 0 && tracks.count > 1 ? tracks.filter(\.needsRepair).map(\.id) : ids
                        model.repair(targets)
                    }
                    .buttonStyle(.dj(lowCount > 0 ? .accent : .outline, fullWidth: true))
                    .disabled(allBusy(ids, kind: .repair))
                }
            }
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// Every track already has this tool queued or running (the queue ignores repeats anyway).
    private func allBusy(_ ids: [Track.ID], kind: Job.Kind) -> Bool {
        ids.allSatisfy { model.job(for: $0, kind: kind)?.state.isActive == true }
    }

    /// A gentle heads-up for very low-bitrate or low-sample-rate sources.
    private func lowSourceNote(_ tracks: [Track]) -> String? {
        let low = tracks.filter(\.isVeryLowSource)
        guard !low.isEmpty else { return nil }
        let advice = "Results vary from sources this rough, so listen before replacing the original."
        if tracks.count == 1, let quality = low.first?.quality {
            let why = quality.sampleRate < 44_100
                ? "This file was recorded at \(DJFormat.kHz(quality.sampleRate))."
                : "This is a \(quality.declaredBitrateKbps ?? 0) kbps file."
            return "\(why) \(advice)"
        }
        return "\(low.count) of these are very low bitrate. \(advice)"
    }

    private func suggestion(tracks: [Track], lowCount: Int) -> String? {
        guard lowCount > 0 else { return nil }
        if tracks.count == 1 { return "Suggested" }
        return "\(lowCount) of \(tracks.count) need it"
    }

    private func repairTitle(tracks: [Track], lowCount: Int) -> String {
        if tracks.count == 1 { return "Repair with Apollo" }
        if lowCount > 0 { return "Repair \(DJFormat.count(lowCount, "Track"))" }
        return "Repair \(tracks.count) Tracks"
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
                Text("Checking quality…").djText(.bodyMedium).foregroundStyle(DJColor.foreground)
                Text("Reading the file and looking for where the highs stop.")
                    .djText(.caption)
                    .foregroundStyle(DJColor.mutedForeground)
                DJProgressBar(fraction: nil, height: 4)
                    .frame(maxWidth: 240)
                    .padding(.top, 2)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .djCard(padding: DJSpace.lg)
        } else if let report = track.quality {
            QualityCard(report: report, fileSize: track.fileSize)
        } else if let error = track.qualityError {
            DJNotice(kind: .error, message: "Couldn't check this file: \(error)")
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
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: DJSpace.sm) {
                        Text(report.summary)
                            .djText(.headline)
                            .foregroundStyle(DJColor.foreground)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: DJSpace.sm)
                        QualityBadge(verdict: report.verdict, large: true)
                    }
                    Text(report.verdict.explanation)
                        .djText(.caption)
                        .foregroundStyle(DJColor.mutedForeground)
                        .fixedSize(horizontal: false, vertical: true)
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

// MARK: - Tools

/// One tool: what it does, its options, its button, and its job(s) for
/// the selection. `suggestion` highlights it ("Suggested").
private struct ToolCard<Options: View, Action: View>: View {
    @Environment(AppModel.self) private var model
    let systemImage: String
    let title: String
    let message: String
    let jobs: [Job]
    let multi: Bool
    var suggestion: String?
    @ViewBuilder var options: Options
    @ViewBuilder var action: Action

    var body: some View {
        VStack(alignment: .leading, spacing: DJSpace.md) {
            // The badge beside the title, or under it when the card is narrow.
            ViewThatFits(in: .horizontal) {
                HStack(spacing: DJSpace.sm) {
                    titleLabel
                    Spacer(minLength: DJSpace.xs)
                    badge
                }
                VStack(alignment: .leading, spacing: DJSpace.sm) {
                    titleLabel
                    badge
                }
            }
            Text(message)
                .djText(.caption)
                .foregroundStyle(DJColor.mutedForeground)
                .fixedSize(horizontal: false, vertical: true)
            options
            Spacer(minLength: 0)
            jobStatus
            action
        }
        .padding(DJSpace.lg)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(DJColor.card, in: RoundedRectangle(cornerRadius: DJRadius.xl))
        .overlay {
            RoundedRectangle(cornerRadius: DJRadius.xl)
                .strokeBorder(suggestion != nil ? DJColor.ring.opacity(0.8) : DJColor.border.opacity(0.8),
                              lineWidth: suggestion != nil ? 1.5 : 1)
        }
    }

    private var titleLabel: some View {
        HStack(spacing: DJSpace.sm) {
            Image(systemName: systemImage)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(suggestion != nil ? DJColor.ring : DJColor.mutedForeground)
                .frame(width: 18)
                .accessibilityHidden(true)
            Text(title)
                .djText(.headline)
                .foregroundStyle(DJColor.foreground)
                .lineLimit(1)
                .fixedSize()
        }
    }

    @ViewBuilder private var badge: some View {
        if let suggestion {
            Text(suggestion)
                .font(.dj(10, weight: 600))
                .foregroundStyle(DJColor.ring)
                .padding(.horizontal, 7)
                .padding(.vertical, 2)
                .background(Capsule().fill(DJColor.ring.opacity(0.14)))
                .fixedSize()
        }
    }

    /// The selection's job for this tool: one row for a single track, a
    /// tally for several.
    @ViewBuilder private var jobStatus: some View {
        if multi {
            let active = jobs.filter(\.state.isActive).count
            let done = jobs.filter { $0.state == .finished }.count
            if active + done > 0 {
                Text([active > 0 ? "\(active) in the queue" : nil, done > 0 ? "\(done) done" : nil]
                    .compactMap { $0 }.joined(separator: " · "))
                    .djText(.caption)
                    .foregroundStyle(DJColor.mutedForeground)
            }
        } else if let job = jobs.first, job.state != .cancelled {
            JobRow(
                job: job, showsTrack: false,
                cancel: { model.cancel(job.id) },
                reveal: { NSWorkspace.shared.activateFileViewerSelecting([$0]) },
                retry: { model.retry(job.id) }
            )
            .padding(DJSpace.sm)
            .background(DJColor.muted.opacity(0.5), in: RoundedRectangle(cornerRadius: DJRadius.lg))
        }
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
                case .stems(let model, _, let stems):
                    HStack(spacing: 4) {
                        ForEach(model.stemNames.filter { stems[$0] != nil }, id: \.self) { name in
                            Text(name)
                                .font(.dj(11, weight: 500))
                                .foregroundStyle(DJColor.foreground)
                                .padding(.horizontal, 7)
                                .padding(.vertical, 1)
                                .background(Capsule().fill(DJColor.muted))
                        }
                    }
                case .repaired(let output):
                    Text(output.lastPathComponent)
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

    private var icon: String {
        switch result.kind {
        case .stems: "square.3.layers.3d"
        case .repaired: "wand.and.stars"
        }
    }

    private var title: String {
        switch result.kind {
        case .stems(let model, _, _): "Stems · \(model.modelName)"
        case .repaired: "Repaired with Apollo"
        }
    }
}
