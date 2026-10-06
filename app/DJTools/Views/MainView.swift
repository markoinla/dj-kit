import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// The main window: dropped tracks in the sidebar, the selection's detail,
/// and the job queue at the right edge. Dropping files or folders anywhere
/// in the window adds them.
struct MainView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openSettings) private var openSettings
    @State private var selection: Set<Track.ID> = []
    @State private var isTargeted = false
    @State private var isImporting = false

    var body: some View {
        @Bindable var model = model
        NavigationSplitView {
            TrackSidebar(selection: $selection)
                .navigationSplitViewColumnWidth(min: DJSize.sidebarMin, ideal: DJSize.sidebarIdeal, max: DJSize.sidebarMax)
        } detail: {
            HStack(spacing: 0) {
                detail
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                if model.isShowingJobs {
                    Rectangle().fill(DJColor.border).frame(width: 1)
                    JobsPanel { model.isShowingJobs = false }
                        .frame(width: DJSize.jobsPanelWidth)
                        .transition(.move(edge: .trailing))
                }
            }
            .animation(.snappy(duration: 0.2), value: model.isShowingJobs)
            .background(DJColor.background)
            .toolbar { toolbar }
            .safeAreaInset(edge: .top, spacing: 0) {
                if let notice = model.notice {
                    DJNotice(kind: .info, message: notice) { model.notice = nil }
                        .padding(.horizontal, DJSpace.xxl)
                        .padding(.top, DJSpace.sm)
                }
            }
        }
        .hidingWindowTitle()
        .hiddenToolbarBackground()
        .dropDestination(for: URL.self) { urls, _ in
            add(urls)
            return !urls.isEmpty
        } isTargeted: { isTargeted = $0 }
        .overlay { if isTargeted { DropOverlay() } }
        .fileImporter(
            isPresented: $isImporting,
            allowedContentTypes: [.audio, .folder],
            allowsMultipleSelection: true
        ) { result in
            if case .success(let urls) = result { add(urls) }
        }
        .sheet(item: $model.apolloSetup) { request in
            ApolloSetupSheet(request: request)
        }
        .onChange(of: model.tracks.map(\.id)) { _, ids in
            selection.formIntersection(ids)
        }
        .onChange(of: DockStatus(model: model)) { _, status in status.show() }
    }

    /// Adds, and selects the first new track when nothing is selected.
    private func add(_ urls: [URL]) {
        let added = model.add(urls)
        if selection.isEmpty, let first = added.first { selection = [first] }
    }

    private var selectedIDs: [Track.ID] {
        model.tracks.map(\.id).filter(selection.contains)
    }

    @ViewBuilder private var detail: some View {
        let ids = selectedIDs
        if ids.isEmpty {
            WelcomeView(isTargeted: isTargeted, hasTracks: !model.tracks.isEmpty) { isImporting = true }
        } else {
            TrackDetailView(ids: ids)
                .id(ids)
        }
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            if model.engines.isFake {
                Text("Demo engines")
                    .font(.dj(11, weight: 600))
                    .foregroundStyle(DJColor.marker)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(DJColor.markerSurface))
                    .help("Running on fake engines (-useFakeEngines): jobs sleep and write placeholder files.")
            }
            Button("Add Tracks…", systemImage: "plus") { isImporting = true }
                .keyboardShortcut("o")
                .help("Add audio files or a folder (⌘O)")
            Button("Queue", systemImage: model.activeJobCount > 0 ? "list.bullet.rectangle.fill" : "list.bullet.rectangle") {
                model.isShowingJobs.toggle()
            }
            .keyboardShortcut("j")
            .help(model.activeJobCount > 0 ? "\(DJFormat.count(model.activeJobCount, "job")) in the queue (⌘J)" : "Show the queue (⌘J)")
            Button("Settings", systemImage: "gearshape") { openSettings() }
                .help("Output folder, default stem model, Apollo (⌘,)")
        }
    }
}

/// The Dock tile: a badge with the number of active jobs.
private struct DockStatus: Equatable {
    let active: Int

    @MainActor init(model: AppModel) {
        active = model.activeJobCount
    }

    @MainActor func show() {
        NSApp.dockTile.badgeLabel = active > 0 ? "\(active)" : nil
    }
}
