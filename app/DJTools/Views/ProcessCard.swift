import AppKit
import AudioExport
import SwiftUI

/// The Process steps for one or more tracks — Repair → Normalize → Stems —
/// the file type and the Process button. Starts from the last run's recipe;
/// Repair starts from the quality check's suggestion.
struct ProcessCard: View {
    @Environment(AppModel.self) private var model
    let ids: [Track.ID]
    /// In the drop sheet: Return processes, and there's Not Now.
    var inSheet = false
    var done: () -> Void = {}
    var notNow: (() -> Void)?
    @State private var recipe: ProcessRecipe

    init(ids: [Track.ID], initial: ProcessRecipe, inSheet: Bool = false,
         done: @escaping () -> Void = {}, notNow: (() -> Void)? = nil) {
        self.ids = ids
        self.inSheet = inSheet
        self.done = done
        self.notNow = notNow
        _recipe = State(initialValue: initial)
    }

    var body: some View {
        let tracks = ids.compactMap(model.track)
        VStack(spacing: 0) {
            StepRow(systemImage: "wand.and.stars", title: "Repair", isOn: repairBinding(tracks)) {
                repairDetail(tracks)
            } options: {
                EmptyView()
            }
            .help(repairHelp(tracks))
            DJDivider()
            StepRow(systemImage: "speaker.wave.2", title: "Normalize", isOn: $recipe.normalize) {
                NormalizeDetail(tracks: tracks, target: model.settings.loudnessTarget)
            } options: {
                TargetMenu()
            }
            .task(id: ids) { model.measureLoudnessIfNeeded(Array(ids.prefix(12))) }
            DJDivider()
            StepRow(systemImage: "square.3.layers.3d", title: "Stems", isOn: $recipe.stems) {
                EmptyView()
            } options: {
                StemModelMenu(selection: $recipe.stemModel)
                StemKeepMenu(model: recipe.stemModel, choice: $recipe.stemChoice)
            }
            DJDivider()
            footer(tracks)
            if !inSheet { jobStatus(tracks) }
        }
        .djCard()
    }

    // MARK: Repair

    private func lossyCount(_ tracks: [Track]) -> Int { tracks.filter(\.needsRepair).count }

    private func repairBinding(_ tracks: [Track]) -> Binding<Bool> {
        let suggested = lossyCount(tracks) > 0
        return Binding(
            get: { recipe.repair == .on || (recipe.repair == .suggested && suggested) },
            set: { recipe.repair = $0 ? .on : .off }
        )
    }

    private func repairIsOn(_ tracks: [Track]) -> Bool { repairBinding(tracks).wrappedValue }

    /// Where the highs stop; amber with a dot when the file is lossy and
    /// Repair is off.
    @ViewBuilder private func repairDetail(_ tracks: [Track]) -> some View {
        let lossy = lossyCount(tracks)
        let flagged = lossy > 0 && !repairIsOn(tracks)
        HStack(spacing: 5) {
            if flagged {
                Circle().fill(DJColor.marker).frame(width: 6, height: 6)
            }
            Text(repairText(tracks, lossy: lossy))
                .foregroundStyle(flagged ? DJColor.marker : DJColor.mutedForeground)
        }
    }

    private func repairText(_ tracks: [Track], lossy: Int) -> String {
        if tracks.count > 1 {
            let checking = tracks.filter { $0.verdict == nil && $0.qualityError == nil }.count
            if lossy > 0 { return "\(lossy) of \(tracks.count) lossy" }
            return checking > 0 ? "Checking…" : "None lossy"
        }
        guard let track = tracks.first else { return "" }
        guard let quality = track.quality else { return track.qualityError == nil ? "Checking…" : "Not checked" }
        if quality.verdict == .lossless { return "Lossless" }
        if let cutoff = quality.cutoffHz { return "Cuts at \(DJFormat.kHz(cutoff))" }
        return quality.verdict.label
    }

    private func repairHelp(_ tracks: [Track]) -> String {
        var lines: [String] = []
        if model.apolloState != .ready { lines.append("The first repair downloads the model (66 MB).") }
        if tracks.contains(where: \.isVeryLowSource) { lines.append("Very low-quality source: results vary.") }
        return lines.joined(separator: " ")
    }

    // MARK: Footer

    private func footer(_ tracks: [Track]) -> some View {
        let anyStep = repairIsOn(tracks) || recipe.normalize || recipe.stems
        let busy = !tracks.isEmpty && tracks.allSatisfy { processJob($0.id)?.state.isActive == true }
        let canRun = anyStep && !busy && tracks.contains(where: \.fileExists)
        return HStack(spacing: DJSpace.sm) {
            FormatMenu(selection: $recipe.format)
            if repairIsOn(tracks), !recipe.format.isLossless {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 10))
                    .foregroundStyle(DJColor.marker)
                    .help("MP3 drops the highs Repair rebuilds. Lossless keeps them.")
            }
            Spacer(minLength: DJSpace.md)
            if let notNow {
                Button("Not Now", action: notNow)
                    .buttonStyle(.dj(.ghost))
                    .keyboardShortcut(.cancelAction)
            }
            processButton(tracks)
                .disabled(!canRun)
        }
        .padding(.horizontal, DJSpace.md)
        .padding(.vertical, 10)
    }

    @ViewBuilder private func processButton(_ tracks: [Track]) -> some View {
        let button = Button(tracks.count > 1 ? "Process \(tracks.count) Tracks" : "Process", systemImage: "play.fill") {
            // An untouched Repair stays a suggestion, settled per track.
            model.process(tracks.map(\.id), recipe: recipe)
            done()
        }
        .buttonStyle(.dj(.primary))
        if inSheet {
            button.keyboardShortcut(.defaultAction)
        } else {
            button.keyboardShortcut(.return, modifiers: .command)
        }
    }

    // MARK: Job

    private func processJob(_ id: Track.ID) -> Job? {
        model.job(for: id, kind: .process(recipe, model.settings.loudnessTarget))
    }

    @ViewBuilder private func jobStatus(_ tracks: [Track]) -> some View {
        let jobs = tracks.compactMap { processJob($0.id) }
        if tracks.count > 1 {
            let active = jobs.filter(\.state.isActive).count
            let finished = jobs.filter { $0.state == .finished }.count
            if active + finished > 0 {
                DJDivider()
                Text([active > 0 ? "\(active) in the queue" : nil, finished > 0 ? "\(finished) done" : nil]
                    .compactMap { $0 }.joined(separator: " · "))
                    .djText(.caption)
                    .foregroundStyle(DJColor.mutedForeground)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, DJSpace.md)
                    .padding(.vertical, 10)
            }
        } else if let job = jobs.first, job.state != .cancelled {
            DJDivider()
            JobRow(
                job: job, showsTrack: false,
                cancel: { model.cancel(job.id) },
                reveal: { NSWorkspace.shared.activateFileViewerSelecting([$0]) },
                retry: { model.retry(job.id) }
            )
            .padding(.horizontal, DJSpace.md)
            .padding(.vertical, DJSpace.sm)
        }
    }
}

/// One step: icon, name, a short detail, its options (while on) and a switch.
private struct StepRow<Detail: View, Options: View>: View {
    let systemImage: String
    let title: String
    @Binding var isOn: Bool
    @ViewBuilder var detail: Detail
    @ViewBuilder var options: Options

    var body: some View {
        HStack(spacing: DJSpace.sm) {
            Image(systemName: systemImage)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(isOn ? DJColor.ring : DJColor.mutedForeground)
                .frame(width: 18)
                .accessibilityHidden(true)
            Text(title)
                .djText(.bodyMedium)
                .foregroundStyle(isOn ? DJColor.foreground : DJColor.mutedForeground)
                .fixedSize()
            detail
                .djText(.caption)
                .foregroundStyle(DJColor.mutedForeground)
                .monospacedDigit()
                .lineLimit(1)
            Spacer(minLength: DJSpace.sm)
            if isOn { options }
            Toggle(title, isOn: $isOn)
                .toggleStyle(.djSwitch)
        }
        .frame(minHeight: 26)
        .padding(.horizontal, DJSpace.md)
        .padding(.vertical, 8)
        .contentShape(Rectangle())
        .animation(.snappy(duration: 0.15), value: isOn)
    }
}

/// "−6.2 → −10.0 LUFS"; amber when the peak ceiling caps the gain.
private struct NormalizeDetail: View {
    @Environment(AppModel.self) private var model
    let tracks: [Track]
    let target: DJLoudnessTarget

    var body: some View {
        if tracks.count > 1 {
            let levels = tracks.compactMap(\.loudness).filter { !$0.isSilent }.map(\.integratedLUFS)
            if let low = levels.min(), let high = levels.max() {
                Text(low == high ? "Now \(DJFormat.lufs(low))" : "Now \(DJFormat.signed(low)) to \(DJFormat.lufs(high))")
            }
        } else if let track = tracks.first {
            if let report = track.loudness {
                if report.isSilent {
                    Text("Silent")
                } else {
                    let plan = model.engines.loudness.plan(for: report, target: target)
                    Text("\(DJFormat.signed(report.integratedLUFS)) → \(DJFormat.lufs(plan.resultingLUFS))")
                        .foregroundStyle(plan.limitedByCeiling ? DJColor.marker : DJColor.mutedForeground)
                        .help(plan.limitedByCeiling
                              ? "Capped by the \(DJFormat.dBTP(plan.ceilingDBTP)) peak ceiling (gain only, no limiter)."
                              : "\(DJFormat.gain(plan.gainDB)), gain only")
                }
            } else if model.job(for: track.id, kind: .loudness)?.state.isActive == true {
                Text("Measuring…")
            } else if let error = track.loudnessError {
                Text("Couldn't measure").help(error)
            }
        }
    }
}

/// "−10 LUFS ⌄": Settings' target loudness.
private struct TargetMenu: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var settings = model.settings
        CompactMenu(label: DJFormat.lufs(settings.targetLUFS, decimals: 0)) {
            Picker("Target", selection: $settings.targetLUFS) {
                ForEach(AppSettings.targetChoices, id: \.self) { Text(DJFormat.lufs($0, decimals: 0)).tag($0) }
            }
            .pickerStyle(.inline)
        }
        .help("Target loudness")
    }
}

private struct StemModelMenu: View {
    @Binding var selection: DJStemModel

    var body: some View {
        CompactMenu(label: selection.title) {
            Picker("Model", selection: $selection) {
                ForEach(DJStemModel.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.inline)
        }
        .help(selection.helper)
    }
}

/// Which stems to keep: two presets, or any mix of stems and Instrumental.
private struct StemKeepMenu: View {
    let model: DJStemModel
    @Binding var choice: DJStemChoice

    var body: some View {
        let outputs = Set(choice.outputs(for: model))
        CompactMenu(label: label(outputs)) {
            Button("All") { choice = .all }
            Button("Acapella + Instrumental") { choice = .acapellaInstrumental }
            Divider()
            ForEach(model.stemNames + [DJStemChoice.instrumental], id: \.self) { name in
                Toggle(name.capitalized, isOn: Binding(
                    get: { outputs.contains(name) },
                    set: { on in
                        var next = outputs
                        if on { next.insert(name) } else { next.remove(name) }
                        if !next.isEmpty { choice = .custom(next) }
                    }
                ))
            }
        }
        .help("Stems to keep")
    }

    private func label(_ outputs: Set<String>) -> String {
        if outputs == Set(model.stemNames) { return "All \(model.stemNames.count)" }
        if outputs == ["vocals", DJStemChoice.instrumental] { return "Acapella + Inst." }
        let names = (model.stemNames + [DJStemChoice.instrumental]).filter(outputs.contains)
        return names.count <= 2 ? names.map(\.capitalized).joined(separator: " + ") : "\(names.count) stems"
    }
}

/// "AIFF ⌄": the file type for this run (the last one's until changed).
struct FormatMenu: View {
    @Binding var selection: AudioFileFormat

    var body: some View {
        CompactMenu(label: selection.shortTitle) {
            Picker("Lossless", selection: $selection) {
                ForEach(AudioFileFormat.allCases.filter(\.isLossless)) { Text($0.title).tag($0) }
            }
            .pickerStyle(.inline)
            Picker("MP3", selection: $selection) {
                ForEach(AudioFileFormat.allCases.filter { !$0.isLossless }) { Text($0.title).tag($0) }
            }
            .pickerStyle(.inline)
        }
        .help("Save as")
        .accessibilityLabel("Save as \(selection.title)")
    }
}

/// A small ghost button with a value and a chevron that opens a menu.
private struct CompactMenu<Content: View>: View {
    let label: String
    @ViewBuilder var content: Content

    var body: some View {
        Menu {
            content
        } label: {
            HStack(spacing: 4) {
                Text(label)
                    .font(.dj(12, weight: 600))
                    .foregroundStyle(DJColor.foreground)
                    .monospacedDigit()
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(DJColor.mutedForeground)
            }
            .frame(minHeight: 20)
            .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .buttonStyle(.dj(.ghost, size: .small))
        .menuIndicator(.hidden)
        .fixedSize()
    }
}

/// The drop "wizard": the new tracks and their Process steps. Return runs
/// them, Escape just keeps them in the list.
struct ProcessSheet: View {
    @Environment(AppModel.self) private var model
    let request: ProcessRequest

    var body: some View {
        let tracks = request.trackIDs.compactMap(model.track)
        VStack(alignment: .leading, spacing: DJSpace.lg) {
            HStack(spacing: DJSpace.md) {
                if tracks.count == 1, let track = tracks.first {
                    FormatTile(container: track.container, size: 36)
                    Text(track.name)
                        .font(.dj(15, weight: 650))
                        .foregroundStyle(DJColor.foreground)
                        .lineLimit(2)
                    Spacer(minLength: DJSpace.sm)
                    if let verdict = track.verdict { QualityBadge(verdict: verdict) }
                } else {
                    Text(DJFormat.count(tracks.count, "track"))
                        .font(.dj(15, weight: 650))
                        .foregroundStyle(DJColor.foreground)
                    Spacer()
                }
            }
            ProcessCard(ids: request.trackIDs, initial: model.settings.lastRecipe, inSheet: true,
                        done: { model.processRequest = nil },
                        notNow: { model.processRequest = nil })
        }
        .padding(DJSpace.xl)
        .frame(width: 540)
        .background(DJColor.background)
    }
}
