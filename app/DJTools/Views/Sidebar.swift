import AppKit
import SwiftUI

/// The sidebar: the wordmark and the dropped tracks (multi-select), in
/// three groups: Processing, Ready and Done.
struct TrackSidebar: View {
    @Environment(AppModel.self) private var model
    @Binding var selection: Set<Track.ID>

    var body: some View {
        let groups = model.trackGroups
        List(selection: $selection) {
            ForEach(Array(groups.enumerated()), id: \.element.stage) { index, group in
                Section {
                    ForEach(group.tracks) { track in
                        SidebarTrackRow(track: track, stage: group.stage)
                            .tag(track.id)
                            .contextMenu { TrackMenu(ids: menuTargets(track.id), selection: $selection) }
                    }
                } header: {
                    SidebarHeader(title: group.stage.title, count: group.tracks.count) {
                        if index == 0, model.tracks.contains(where: { !$0.fileExists }) {
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
        .overlay {
            if model.tracks.isEmpty {
                VStack(spacing: DJSpace.xs) {
                    Text("No tracks yet").djText(.headline).foregroundStyle(DJColor.foreground)
                    Text("Drop audio here").djText(.caption).foregroundStyle(DJColor.mutedForeground)
                }
            }
        }
    }

    /// A right-click on a selected row acts on the whole selection.
    private func menuTargets(_ id: Track.ID) -> [Track.ID] {
        selection.contains(id) ? model.tracks.map(\.id).filter(selection.contains) : [id]
    }
}

/// `TrackRow` fed from the model (also drawn by `-renderPreviews`).
struct SidebarTrackRow: View {
    @Environment(AppModel.self) private var model
    let track: Track
    let stage: TrackStage

    var body: some View {
        TrackRow(track: track, stage: stage, job: model.processJob(for: track.id),
                 isChecking: model.job(for: track.id, kind: .quality)?.state.isActive == true)
    }
}

extension TrackStage {
    /// The sidebar group's label.
    var title: String {
        switch self {
        case .processing: "Processing"
        case .ready: "Ready"
        case .done: "Done"
        }
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

/// Right-click on tracks (all the selected ones when the row is selected).
struct TrackMenu: View {
    @Environment(AppModel.self) private var model
    let ids: [Track.ID]
    @Binding var selection: Set<Track.ID>

    var body: some View {
        let identified = ids.allSatisfy { model.track($0)?.identifiedAt != nil }
        Button(ids.count > 1 ? "Identify \(ids.count) Tracks" : identified ? "Identify Again" : "Identify") { model.identify(ids) }
        let pending = ids.filter { model.track($0)?.hasPendingIdentity == true }
        if !pending.isEmpty {
            Button(pending.count > 1 ? "Apply \(pending.count) Track IDs" : "Apply Track ID") { model.applyIdentity(pending) }
        }
        Divider()
        Button(ids.count > 1 ? "Process \(ids.count) Tracks…" : "Process…") {
            selection = Set(ids)
        }
        Button("Check Quality Again") { model.checkQuality(ids) }
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
