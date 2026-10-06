import AppKit
import SwiftUI

/// The sidebar: the wordmark, the dropped tracks (multi-select), and the
/// running heavy job at the foot.
struct TrackSidebar: View {
    @Environment(AppModel.self) private var model
    @Binding var selection: Set<Track.ID>

    var body: some View {
        List(selection: $selection) {
            if !model.tracks.isEmpty {
                Section {
                    ForEach(model.tracks) { track in
                        TrackRow(track: track, job: model.activeJob(for: track.id))
                            .tag(track.id)
                            .contextMenu { TrackMenu(ids: menuTargets(track.id), selection: $selection) }
                    }
                } header: {
                    SidebarHeader(title: "Tracks", count: model.tracks.count) {
                        if model.tracks.contains(where: { !$0.fileExists }) {
                            DJLinkButton("Remove Missing") {
                                model.remove(Set(model.tracks.filter { !$0.fileExists }.map(\.id)))
                            }
                            .help("Take tracks whose files are gone off the list")
                        }
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .scrollContentBackground(.hidden)
        .background(DJColor.sidebar)
        .onDeleteCommand { model.remove(selection) }
        .safeAreaInset(edge: .top, spacing: 0) {
            SidebarBrand()
                .padding(.horizontal, DJSpace.lg)
                .padding(.top, DJSpace.xs)
                .padding(.bottom, DJSpace.md)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(DJColor.sidebar)
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if let job = model.runningHeavyJob {
                SidebarActivityCard(job: job, waiting: model.activeHeavyJobs.count - 1) {
                    model.isShowingJobs = true
                }
            }
        }
        .overlay {
            if model.tracks.isEmpty {
                VStack(spacing: DJSpace.xs) {
                    Text("No tracks yet").djText(.headline).foregroundStyle(DJColor.foreground)
                    Text("Drop audio into the window.").djText(.caption).foregroundStyle(DJColor.mutedForeground)
                }
            }
        }
    }

    /// A right-click on a selected row acts on the whole selection.
    private func menuTargets(_ id: Track.ID) -> [Track.ID] {
        selection.contains(id) ? model.tracks.map(\.id).filter(selection.contains) : [id]
    }
}

/// The wordmark: Wax's logo spot, in the same flame orange.
struct SidebarBrand: View {
    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: "waveform")
                .font(.system(size: 15, weight: .bold))
                .foregroundStyle(DJColor.flame)
            Text("DJ Tools")
                .font(.dj(17, weight: 750))
                .tracking(-0.4)
                .foregroundStyle(DJColor.foreground)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("DJ Tools")
    }
}

/// "TRACKS 6" — the sidebar's group label.
struct SidebarHeader<Trailing: View>: View {
    let title: String
    let count: Int?
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(spacing: DJSpace.xs) {
            Text(title).djText(.label).foregroundStyle(DJColor.mutedForeground)
            if let count {
                Text("\(count)")
                    .font(.dj(10, weight: 500))
                    .foregroundStyle(DJColor.mutedForeground.opacity(0.7))
            }
            Spacer()
            trailing
                .padding(.trailing, DJSpace.md)
        }
    }
}

extension SidebarHeader where Trailing == EmptyView {
    init(title: String, count: Int?) {
        self.init(title: title, count: count) { EmptyView() }
    }
}

/// The heavy job that's running, at the sidebar's foot. Click for the queue.
struct SidebarActivityCard: View {
    let job: Job
    let waiting: Int
    var open: () -> Void = {}

    var body: some View {
        Button(action: open) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Image(systemName: job.kind.systemImage)
                        .font(.system(size: 11))
                        .foregroundStyle(DJColor.ring)
                    Text(job.kind == .repair ? "Repairing" : "Separating stems")
                        .djText(.captionMedium)
                        .foregroundStyle(DJColor.foreground)
                    Spacer(minLength: 0)
                    Text(job.progress.map(DJFormat.percent) ?? "")
                        .djText(.caption)
                        .monospacedDigit()
                        .foregroundStyle(DJColor.mutedForeground)
                }
                Text(job.trackName)
                    .djText(.caption)
                    .foregroundStyle(DJColor.mutedForeground)
                    .lineLimit(1)
                    .truncationMode(.middle)
                DJProgressBar(fraction: job.progress, height: 3, tint: DJColor.ring)
                if waiting > 0 {
                    Text("\(waiting) more waiting")
                        .djText(.caption)
                        .foregroundStyle(DJColor.mutedForeground)
                }
            }
            .padding(DJSpace.md)
            .background(DJColor.background, in: RoundedRectangle(cornerRadius: DJRadius.lg))
            .overlay(RoundedRectangle(cornerRadius: DJRadius.lg).strokeBorder(DJColor.border))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(DJSpace.md)
        .background(DJColor.sidebar)
        .help("Show the queue")
    }
}

/// Right-click on tracks (all the selected ones when the row is selected).
struct TrackMenu: View {
    @Environment(AppModel.self) private var model
    let ids: [Track.ID]
    @Binding var selection: Set<Track.ID>

    var body: some View {
        Button("Check Quality Again") { model.checkQuality(ids) }
        Button(ids.count > 1 ? "Separate \(ids.count) Tracks' Stems" : "Separate Stems") {
            model.separateStems(ids, model: model.settings.defaultStemModel)
        }
        Button(ids.count > 1 ? "Repair \(ids.count) Tracks with Apollo" : "Repair with Apollo") {
            model.repair(ids)
        }
        Button(ids.count > 1 ? "Normalize \(ids.count) Tracks' Loudness" : "Normalize Loudness") {
            model.normalize(ids)
        }
        Divider()
        Button("Reveal in Finder") {
            NSWorkspace.shared.activateFileViewerSelecting(ids.compactMap { model.track($0)?.url })
        }
        Divider()
        Button(ids.count > 1 ? "Remove \(ids.count) from List" : "Remove from List") {
            model.remove(Set(ids))
            selection.subtract(ids)
        }
    }
}
