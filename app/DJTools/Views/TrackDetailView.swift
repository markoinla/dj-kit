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
        Group {
            if tracks.count == 1, let track = tracks.first {
                SingleTrackDetail(track: track)
            } else {
                MultiTrackDetail(tracks: tracks)
            }
        }
        .padding(.horizontal, DJSpace.xxxl)
        .padding(.top, DJSpace.lg)
        .padding(.bottom, DJSpace.xxxl)
        .frame(maxWidth: DJSize.detailMaxWidth, alignment: .leading)
    }
}

// MARK: - One track

/// One track in one of three states, all derived from its jobs and results:
/// setup (not processed yet, the last run failed, or Process Again),
/// processing (a run queued or going) and done.
private struct SingleTrackDetail: View {
    @Environment(AppModel.self) private var model
    let track: Track
    /// Tracks put back to setup with Process Again.
    @State private var again: Set<Track.ID> = []

    var body: some View {
        let job = model.processJob(for: track.id)
        let stage = model.stage(of: track)
        let latest = track.latestResult
        let showsDone = stage == .done && !again.contains(track.id)
        VStack(alignment: .leading, spacing: DJSpace.xl) {
            TrackHeader(track: track, finishedAt: showsDone ? latest?.result.finishedAt : nil)
            if !track.fileExists {
                DJNotice(kind: .warning, message: "File missing")
            }
            if stage == .processing, let job {
                ProcessRunCard(track: track, job: job)
            } else if showsDone, let latest {
                ProcessDoneCard(track: track, files: latest.files) { again.insert(track.id) }
                OutputSection(files: latest.files)
            } else {
                if let job, job.state.isUnsuccessful {
                    RunNotice(job: job)
                }
                ProcessSetupCard(ids: [track.id], initial: model.settings.lastRecipe) {
                    again.remove(track.id)
                }
            }
        }
    }
}

/// The last run's failure (or that it was cancelled), above the steps.
private struct RunNotice: View {
    @Environment(AppModel.self) private var model
    let job: Job

    var body: some View {
        if case .failed(let message) = job.state {
            DJNotice(kind: .error, message: message) { model.dismissJob(job.id) }
        } else {
            DJNotice(kind: .info, message: "Cancelled") { model.dismissJob(job.id) }
        }
    }
}

/// Artwork (or the format tile), the name, "MP3 · 5:12", and when the
/// latest run finished.
private struct TrackHeader: View {
    let track: Track
    let finishedAt: Date?

    var body: some View {
        HStack(alignment: .center, spacing: DJSpace.lg) {
            HeaderArtwork(track: track)
            VStack(alignment: .leading, spacing: 5) {
                Text(track.name)
                    .djText(.display)
                    .foregroundStyle(DJColor.foreground)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 6) {
                    Text(meta)
                        .foregroundStyle(DJColor.mutedForeground)
                    if let finishedAt {
                        Text("·").foregroundStyle(DJColor.mutedForeground)
                        Label("Done · \(finishedAt.formatted(.relative(presentation: .named)))", systemImage: "checkmark")
                            .labelStyle(TightLabel())
                            .foregroundStyle(DJColor.success)
                    }
                }
                .djText(.caption)
                .monospacedDigit()
                .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
    }

    private var meta: String {
        [DJFormat.container(track.container), track.quality.map { DJFormat.duration($0.duration) }]
            .compactMap { $0 }.joined(separator: " · ")
    }
}

/// An icon and its title, close together.
private struct TightLabel: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 3) {
            configuration.icon.font(.system(size: 9, weight: .bold))
            configuration.title
        }
    }
}

/// The release's cover once Track ID found one, else the format tile.
private struct HeaderArtwork: View {
    let track: Track

    var body: some View {
        if let url = track.identityStatus == .dismissed ? nil : track.identity?.artworkURL {
            AsyncImage(url: url) { phase in
                if let image = phase.image {
                    image.resizable().aspectRatio(contentMode: .fill)
                } else {
                    FormatTile(container: track.container, size: DJSize.headerTile)
                }
            }
            .frame(width: DJSize.headerTile, height: DJSize.headerTile)
            .clipShape(RoundedRectangle(cornerRadius: DJRadius.lg))
            .overlay(RoundedRectangle(cornerRadius: DJRadius.lg).strokeBorder(DJColor.border.opacity(0.6)))
            .accessibilityHidden(true)
        } else {
            FormatTile(container: track.container, size: DJSize.headerTile)
        }
    }
}

// MARK: - Output

/// The finished files: the track and one chip per stem, each draggable
/// straight into Rekordbox.
private struct OutputSection: View {
    let files: ProcessedFiles

    var body: some View {
        VStack(alignment: .leading, spacing: DJSpace.sm) {
            DJSectionHeader("Output", detail: folder.map(DJFormat.path))
            VStack(spacing: 0) {
                if let output = files.output {
                    OutputRow(url: output) {
                        FormatTile(container: output.pathExtension, size: 28)
                    } content: {
                        Text(output.lastPathComponent)
                            .djText(.bodyMedium)
                            .foregroundStyle(DJColor.foreground)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    .draggableFile(output)
                }
                if let stems = files.stems, !stems.isEmpty, let stemsFolder = files.stemsFolder {
                    if files.output != nil { DJDivider() }
                    OutputRow(url: stemsFolder) {
                        Image(systemName: "square.3.layers.3d")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(DJColor.mutedForeground)
                            .frame(width: 28, height: 28)
                            .background(DJColor.muted, in: RoundedRectangle(cornerRadius: DJRadius.sm))
                    } content: {
                        HStack(spacing: 6) {
                            ForEach(stemOrder(stems), id: \.self) { name in
                                StemChip(name: name, url: stems[name]!)
                            }
                        }
                    }
                }
            }
            .djCard()
        }
    }

    private var folder: URL? {
        files.output?.deletingLastPathComponent() ?? files.stemsFolder?.deletingLastPathComponent()
    }

    /// The model's order, the instrumental last.
    private func stemOrder(_ stems: [String: URL]) -> [String] {
        let known = (files.stemModel ?? .htdemucs6s).stemNames + [DJStemChoice.instrumental]
        return known.filter { stems[$0] != nil } + stems.keys.filter { !known.contains($0) }.sorted()
    }
}

/// A file row: its tile, the name or chips, and Reveal in Finder.
private struct OutputRow<Icon: View, Content: View>: View {
    let url: URL
    @ViewBuilder var icon: Icon
    @ViewBuilder var content: Content

    var body: some View {
        HStack(spacing: DJSpace.md) {
            icon
            content
            Spacer(minLength: DJSpace.md)
            DJIconButton(title: "Reveal in Finder", systemImage: "folder") {
                NSWorkspace.shared.activateFileViewerSelecting([url])
            }
            .disabled(!FileCheck.exists(url))
        }
        .padding(.horizontal, DJSpace.md)
        .padding(.vertical, 9)
        .contentShape(Rectangle())
    }
}

/// "Vocals": one stem file, draggable.
private struct StemChip: View {
    let name: String
    let url: URL

    var body: some View {
        Text(name.capitalized)
            .font(.dj(12, weight: 500))
            .foregroundStyle(DJColor.foreground)
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(Capsule().fill(DJColor.muted))
            .overlay(Capsule().strokeBorder(DJColor.border.opacity(0.8)))
            .contentShape(Capsule())
            .draggableFile(url)
    }
}

extension View {
    /// Drags the file itself (Rekordbox, Finder).
    func draggableFile(_ url: URL) -> some View {
        onDrag { NSItemProvider(contentsOf: url) ?? NSItemProvider() }
            .help("Drag into Rekordbox")
    }
}

// MARK: - Several tracks

/// Several tracks: a count and their verdicts, then the steps for all of
/// them, or each one's progress while any runs.
private struct MultiTrackDetail: View {
    @Environment(AppModel.self) private var model
    let tracks: [Track]

    var body: some View {
        let running = tracks.contains { model.processJob(for: $0.id)?.state.isActive == true }
        VStack(alignment: .leading, spacing: DJSpace.xl) {
            HStack(spacing: DJSpace.lg) {
                ZStack {
                    DJColor.muted
                    Image(systemName: "rectangle.stack")
                        .font(.system(size: 18, weight: .medium))
                        .foregroundStyle(DJColor.mutedForeground.opacity(0.8))
                }
                .frame(width: DJSize.headerTile, height: DJSize.headerTile)
                .clipShape(RoundedRectangle(cornerRadius: DJRadius.lg))
                .overlay(RoundedRectangle(cornerRadius: DJRadius.lg).strokeBorder(DJColor.border.opacity(0.6)))
                VStack(alignment: .leading, spacing: 5) {
                    Text(DJFormat.count(tracks.count, "track"))
                        .djText(.display)
                        .foregroundStyle(DJColor.foreground)
                    Text(breakdown)
                        .djText(.caption)
                        .foregroundStyle(DJColor.mutedForeground)
                }
            }
            if running {
                ProcessRunList(tracks: tracks)
            } else {
                ProcessSetupCard(ids: tracks.map(\.id), initial: model.settings.lastRecipe)
            }
        }
    }

    /// "2 lossy · 1 good · 1 lossless".
    private var breakdown: String {
        let lossy = tracks.filter(\.needsRepair).count
        let good = tracks.filter { $0.verdict == .goodLossy }.count
        let lossless = tracks.filter { $0.verdict == .lossless }.count
        let checking = tracks.filter { $0.verdict == nil }.count
        return [(lossy, "lossy"), (good, "good"), (lossless, "lossless"), (checking, "checking")]
            .filter { $0.0 > 0 }.map { "\($0.0) \($0.1)" }.joined(separator: " · ")
    }
}

// MARK: - Loudness

extension DJNormalizationPlan {
    /// "−6.2 → −10.0 LUFS, −3.8 dB".
    var change: String {
        let from = resultingLUFS - gainDB
        return "\(DJFormat.signed(from)) → \(DJFormat.lufs(resultingLUFS)), \(DJFormat.gain(gainDB))"
    }
}
