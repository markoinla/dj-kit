import AppKit
import SwiftUI

/// The queue at the window's right edge: running, waiting and finished jobs.
struct JobsPanel: View {
    @Environment(AppModel.self) private var model
    var scrolls = true
    var close: () -> Void = {}

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: DJSpace.sm) {
                Text("Queue").djText(.title).foregroundStyle(DJColor.foreground)
                Spacer()
                if model.jobs.contains(where: { !$0.state.isActive }) {
                    DJLinkButton("Clear Finished") { model.clearFinishedJobs() }
                }
                DJIconButton(title: "Hide the queue", systemImage: "xmark", action: close)
            }
            .padding(.horizontal, DJSpace.lg)
            .padding(.top, DJSpace.md)
            .padding(.bottom, DJSpace.sm)
            if scrolls {
                ScrollView { list }
            } else {
                list
            }
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .background(DJColor.sidebar)
    }

    private var list: some View {
        JobsList()
            .padding(.horizontal, DJSpace.lg)
            .padding(.bottom, DJSpace.lg)
    }
}

/// The queue's groups (also drawn by `-renderPreviews`).
struct JobsList: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let jobs = model.visibleJobs
        let running = jobs.filter { $0.state == .running }
        let waiting = jobs.filter { $0.state == .queued }
        let done = jobs.filter { !$0.state.isActive }.reversed()
        VStack(alignment: .leading, spacing: DJSpace.lg) {
            if jobs.isEmpty {
                VStack(spacing: DJSpace.xs) {
                    Image(systemName: "tray")
                        .font(.system(size: 20))
                        .foregroundStyle(DJColor.mutedForeground)
                        .padding(.bottom, DJSpace.xs)
                    Text("Nothing in the queue").djText(.headline).foregroundStyle(DJColor.foreground)
                }
                .frame(maxWidth: .infinity)
                .padding(.top, 60)
            }
            group("Now", running)
            group("Up next", waiting)
            group("Done", Array(done))
        }
    }

    @ViewBuilder
    private func group(_ title: String, _ jobs: [Job], detail: String? = nil) -> some View {
        if !jobs.isEmpty {
            VStack(alignment: .leading, spacing: DJSpace.sm) {
                DJSectionHeader(title, detail: detail)
                VStack(spacing: 0) {
                    ForEach(Array(jobs.enumerated()), id: \.element.id) { index, job in
                        if index > 0 { DJDivider() }
                        JobRow(
                            job: job,
                            cancel: { model.cancel(job.id) },
                            reveal: { NSWorkspace.shared.activateFileViewerSelecting([$0]) },
                            retry: { model.retry(job.id) }
                        )
                        .padding(.horizontal, DJSpace.md)
                        .padding(.vertical, DJSpace.sm)
                    }
                }
                .djCard()
            }
        }
    }
}
