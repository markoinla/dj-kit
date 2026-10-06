import AppKit
import AudioExport
import SwiftUI

// The stepper: ① Analyze → ② Repair → ③ Normalize → ④ Stems, one numbered
// row each, joined by a hairline. The same rows show the setup (switches and
// options), a run going through them (waiting, running, done, skipped) and
// what a finished run did.

// MARK: - Layout

/// A step's circle: its number, a check once done, a dash when skipped.
struct StepMark: View {
    enum Style { case on, off, waiting, running, done, skipped }
    let number: Int
    let style: Style
    static let size: CGFloat = 22

    var body: some View {
        ZStack {
            // Opaque, so the hairline behind stops at the circle.
            Circle().fill(DJColor.card)
            Circle().fill(fill)
            Circle().strokeBorder(stroke, lineWidth: style == .running ? 1.5 : 1)
            symbol
        }
        .frame(width: Self.size, height: Self.size)
        .accessibilityHidden(true)
    }

    @ViewBuilder private var symbol: some View {
        switch style {
        case .done:
            Image(systemName: "checkmark")
                .font(.system(size: 9, weight: .heavy))
                .foregroundStyle(DJColor.card)
        case .skipped:
            Image(systemName: "minus")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(DJColor.mutedForeground.opacity(0.7))
        default:
            Text("\(number)")
                .font(.dj(11, weight: 700))
                .monospacedDigit()
                .foregroundStyle(numberColor)
        }
    }

    private var fill: Color {
        switch style {
        case .on: DJColor.ring
        case .done: DJColor.success
        case .running: DJColor.ring.opacity(0.14)
        default: .clear
        }
    }

    private var stroke: Color {
        switch style {
        case .on, .done: .clear
        case .running: DJColor.ring
        default: DJColor.mutedForeground.opacity(0.35)
        }
    }

    private var numberColor: Color {
        switch style {
        case .on: Color(hex: 0x1F1E1B)
        case .running: DJColor.ring
        default: DJColor.mutedForeground
        }
    }
}

extension StepStage {
    var mark: StepMark.Style {
        switch self {
        case .waiting: .waiting
        case .running: .running
        case .done: .done
        case .skipped: .skipped
        }
    }
}

/// Where each row's circle sits, for the hairline joining them.
private struct StepMarkBounds: PreferenceKey {
    static var defaultValue: [Anchor<CGRect>] { [] }
    static func reduce(value: inout [Anchor<CGRect>], nextValue: () -> [Anchor<CGRect>]) {
        value += nextValue()
    }
}

/// The rows, with a hairline from the first circle to the last.
struct StepList<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        VStack(spacing: 0) { content }
            .padding(.vertical, DJSpace.xs)
            .backgroundPreferenceValue(StepMarkBounds.self) { marks in
                GeometryReader { proxy in
                    if marks.count > 1, let first = marks.first, let last = marks.last {
                        let top = proxy[first], bottom = proxy[last]
                        Rectangle()
                            .fill(DJColor.border)
                            .frame(width: 1, height: max(0, bottom.midY - top.midY))
                            .position(x: top.midX, y: (top.midY + bottom.midY) / 2)
                    }
                }
            }
    }
}

/// One step: its circle, name and a short detail, options or a switch on
/// the right, and an optional line under it (a progress bar, Track ID).
struct StepRow<Detail: View, Trailing: View, Below: View>: View {
    let number: Int
    let mark: StepMark.Style
    let title: String
    @ViewBuilder var detail: Detail
    @ViewBuilder var trailing: Trailing
    @ViewBuilder var below: Below

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: DJSpace.md) {
                StepMark(number: number, style: mark)
                    .anchorPreference(key: StepMarkBounds.self, value: .bounds) { [$0] }
                Text(title)
                    .djText(.bodyMedium)
                    .foregroundStyle(isLit ? DJColor.foreground : DJColor.mutedForeground)
                    .fixedSize()
                detail
                    .djText(.caption)
                    .foregroundStyle(DJColor.mutedForeground)
                    .monospacedDigit()
                    .lineLimit(1)
                Spacer(minLength: DJSpace.sm)
                trailing
            }
            .frame(minHeight: 26)
            if !(below is EmptyView) {
                below
                    .padding(.leading, StepMark.size + DJSpace.md)
            }
        }
        .padding(.horizontal, DJSpace.lg)
        .padding(.vertical, 9)
        .animation(.snappy(duration: 0.15), value: mark)
    }

    private var isLit: Bool { mark == .on || mark == .running || mark == .done }
}

extension StepRow where Below == EmptyView {
    init(number: Int, mark: StepMark.Style, title: String,
         @ViewBuilder detail: () -> Detail, @ViewBuilder trailing: () -> Trailing) {
        self.init(number: number, mark: mark, title: title, detail: detail, trailing: trailing) { EmptyView() }
    }
}

/// A step's thin bar while it runs.
private struct StepBar: View {
    let fraction: Double?

    var body: some View {
        DJProgressBar(fraction: fraction, height: 3, tint: DJColor.ring)
            .frame(maxWidth: 280)
    }
}

/// The card's last row: the file type or a state on the left, the action
/// on the right.
struct StepFooter<Leading: View, Trailing: View>: View {
    @ViewBuilder var leading: Leading
    @ViewBuilder var trailing: Trailing

    var body: some View {
        VStack(spacing: 0) {
            DJDivider()
            HStack(spacing: DJSpace.sm) {
                leading
                Spacer(minLength: DJSpace.md)
                trailing
            }
            .frame(minHeight: 28)
            .padding(.horizontal, DJSpace.lg)
            .padding(.vertical, 10)
        }
    }
}

// MARK: - ① Analyze

/// ① Analyze: the quality check, Track ID and BPM / key, all run on drop
/// (BPM / key also when a track that has none is shown), so this step shows
/// its own progress before anything is chosen. In a run or after one it's ✓,
/// the quality line and BPM / key, with the file's own tags under them when
/// they disagree.
struct AnalyzeRow: View {
    @Environment(AppModel.self) private var model
    let tracks: [Track]
    /// Processing or done: no Track ID line, no actions.
    var compact = false
    @State private var showsQuality = false

    var body: some View {
        StepRow(number: 1, mark: mark, title: "Analyze") {
            detail
        } trailing: {
            if !compact, tracks.count == 1, let track = tracks.first, let report = track.quality {
                DJIconButton(title: "Quality details", systemImage: "info.circle") { showsQuality = true }
                    .popover(isPresented: $showsQuality, arrowEdge: .bottom) {
                        QualityCard(report: report, fileSize: track.fileSize)
                            .frame(width: 480)
                            .padding(DJSpace.md)
                    }
            }
        } below: {
            if isRunning {
                StepBar(fraction: barFraction)
            }
            if tracks.count == 1, let track = tracks.first, !analyzing(track), let mismatch = track.musicalTagMismatch {
                Text(mismatch)
                    .djText(.caption)
                    .foregroundStyle(DJColor.mutedForeground.opacity(0.7))
                    .monospacedDigit()
            }
            if !compact {
                if tracks.count == 1, let track = tracks.first {
                    TrackIDLine(track: track, job: model.job(for: track.id, kind: .identify))
                } else {
                    PendingMatches(tracks: tracks)
                }
            }
        }
        .task(id: tracks.map(\.id)) { model.analyzeIfNeeded(Array(tracks.map(\.id).prefix(12))) }
    }

    private func checking(_ track: Track) -> Bool {
        model.job(for: track.id, kind: .quality)?.state.isActive == true
    }

    private func listening(_ track: Track) -> Bool {
        model.job(for: track.id, kind: .identify)?.state.isActive == true
    }

    private func analyzing(_ track: Track) -> Bool {
        model.job(for: track.id, kind: .analyze)?.state.isActive == true
    }

    private func busy(_ track: Track) -> Bool { checking(track) || listening(track) || analyzing(track) }

    private var isRunning: Bool { tracks.contains(where: busy) }

    private var mark: StepMark.Style {
        if isRunning { return .running }
        if tracks.allSatisfy({ $0.quality != nil }) { return .done }
        if tracks.contains(where: { $0.qualityError != nil }) { return .off }
        return .waiting
    }

    /// The bar under a running Analyze: the share of tracks done, Track ID's
    /// or BPM / key's own progress, or indeterminate for a quality check.
    private var barFraction: Double? {
        if tracks.count > 1 {
            return Double(tracks.filter { !busy($0) }.count) / Double(tracks.count)
        }
        guard let track = tracks.first, !checking(track) else { return nil }
        return model.job(for: track.id, kind: listening(track) ? .identify : .analyze)?.progress
    }

    @ViewBuilder private var detail: some View {
        if tracks.count > 1 {
            let checked = tracks.filter { $0.quality != nil }.count
            let matched = tracks.filter { $0.identity != nil && $0.identityStatus != .dismissed }.count
            Text(["\(checked) of \(tracks.count) checked", matched > 0 ? "\(matched) matched" : nil]
                .compactMap { $0 }.joined(separator: " · "))
        } else if let track = tracks.first {
            HStack(spacing: 5) {
                quality(track)
                if hasQualityLine(track), hasMusicalLine(track) { Text("·") }
                musical(track)
            }
        }
    }

    @ViewBuilder private func quality(_ track: Track) -> some View {
        if checking(track) {
            Text("Checking…")
        } else if let quality = track.quality {
            if listening(track), !compact {
                Text("Listening…")
            } else {
                QualityLine(track: track, quality: quality)
            }
        } else if let error = track.qualityError {
            Text("Couldn't check").help(error)
        } else if listening(track) {
            Text("Listening…")
        }
    }

    private func hasQualityLine(_ track: Track) -> Bool {
        checking(track) || listening(track) || track.quality != nil || track.qualityError != nil
    }

    /// "124 BPM · 8A · Am", the detection's status while it runs, or its failure.
    @ViewBuilder private func musical(_ track: Track) -> some View {
        if let job = model.job(for: track.id, kind: .analyze), job.state.isActive {
            Text(job.statusText ?? "Analyzing…")
        } else if let readout = track.musicalReadout {
            Text(readout)
                .foregroundStyle(DJColor.foreground)
                #if DEBUG
                .help(debugDetails(track))
                #endif
        } else if let error = analysisFailure(track) {
            Text("Couldn't analyze").help(error)
            if !compact {
                DJLinkButton("Try Again") { model.analyze([track.id]) }
                    .disabled(!track.fileExists)
            }
        }
    }

    private func hasMusicalLine(_ track: Track) -> Bool {
        analyzing(track) || track.musicalReadout != nil || analysisFailure(track) != nil
    }

    /// The file's failure (kept), else the model's (couldn't be set up:
    /// shown until the next try, not kept).
    private func analysisFailure(_ track: Track) -> String? {
        if let error = track.analysisError { return error }
        return track.analysis == nil ? model.analysisUnavailable[track.id] : nil
    }

    #if DEBUG
    /// "key margin 0.12 · stability 0.004 · 812 beats · raw 64.0".
    private func debugDetails(_ track: Track) -> String {
        guard let analysis = track.analysis else { return "" }
        var parts: [String] = []
        if let key = analysis.key { parts.append(String(format: "key margin %.3f", key.margin)) }
        if let tempo = analysis.tempo {
            parts.append(String(format: "stability %.4f · %d beats · raw %.2f", tempo.stability, tempo.beatCount, tempo.rawBPM))
        }
        return parts.joined(separator: " · ")
    }
    #endif
}

/// "MP3 128 · ● Low quality": the format and the verdict, the dot coloured
/// only when the file is lossy-sounding.
struct QualityLine: View {
    let track: Track
    let quality: DJQualityReport

    var body: some View {
        HStack(spacing: 5) {
            Text(track.formatLabel)
            Text("·")
            if track.needsRepair {
                Circle().fill(quality.verdict.tint).frame(width: 6, height: 6)
            }
            Text(quality.verdict.label)
                .foregroundStyle(track.needsRepair ? DJColor.foreground : DJColor.mutedForeground)
        }
        .help(quality.summary)
    }
}

/// Track ID under ① for one track: the match to Apply or turn down, "No
/// match", or Identify when it hasn't run. Nothing once applied (the name
/// already says it) or turned down.
private struct TrackIDLine: View {
    @Environment(AppModel.self) private var model
    let track: Track
    let job: Job?

    var body: some View {
        if job?.state.isActive == true {
            EmptyView()
        } else if model.applying.contains(track.id) {
            line { Text("Applying…").foregroundStyle(DJColor.mutedForeground) }
        } else if let identity = track.identity, track.hasPendingIdentity {
            line {
                Text("\(identity.artist) – \(identity.title)")
                    .foregroundStyle(DJColor.foreground)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(details(identity))
                if let warning = warning(identity) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 9))
                        .foregroundStyle(DJColor.marker)
                        .help(warning)
                }
                Button("Apply") { model.applyIdentity([track.id]) }
                    .buttonStyle(.dj(.outline, size: .small))
                    .disabled(!track.fileExists)
                    .help(model.settings.renameOnApply ? "Write tags and rename" : "Write tags")
                DJIconButton(title: "Not This Track", systemImage: "xmark") { model.dismissIdentity([track.id]) }
            }
        } else if track.identifyError != nil {
            line {
                Text("Couldn't identify").foregroundStyle(DJColor.mutedForeground).help(track.identifyError ?? "")
                DJLinkButton("Try Again") { model.identify([track.id]) }
            }
        } else if track.identifiedAt != nil, track.identity == nil {
            line { Text("No match").foregroundStyle(DJColor.mutedForeground) }
        } else if track.identifiedAt == nil {
            line {
                DJLinkButton("Identify") { model.identify([track.id]) }
                    .disabled(!track.fileExists)
            }
        }
    }

    private func line(@ViewBuilder _ content: () -> some View) -> some View {
        HStack(spacing: DJSpace.sm) {
            Image(systemName: "shazam.logo")
                .font(.system(size: 11))
                .foregroundStyle(DJColor.mutedForeground)
                .accessibilityLabel("Track ID")
            content()
        }
        .djText(.caption)
        .frame(minHeight: 24)
    }

    /// "Album · Label · 2024 · House · 3/3 listens".
    private func details(_ identity: DJTrackIdentity) -> String {
        ([identity.album, identity.label, identity.year, identity.genre] + ["\(identity.hits)/\(identity.listens) listens"])
            .compactMap { $0 }.joined(separator: " · ")
    }

    private func warning(_ identity: DJTrackIdentity) -> String? {
        if track.identityLengthMismatch, let expected = identity.durationSeconds, let actual = track.quality?.duration {
            return "Release is \(DJFormat.duration(expected)), file is \(DJFormat.duration(actual)): maybe another mix"
        }
        return identity.isStrong ? nil : "Weak match"
    }
}

/// Track ID under ① for several tracks: "3 matches · Apply 3".
private struct PendingMatches: View {
    @Environment(AppModel.self) private var model
    let tracks: [Track]

    var body: some View {
        let pending = tracks.filter(\.hasPendingIdentity)
        if !pending.isEmpty {
            HStack(spacing: DJSpace.sm) {
                Image(systemName: "shazam.logo")
                    .font(.system(size: 11))
                    .foregroundStyle(DJColor.mutedForeground)
                Text(DJFormat.count(pending.count, "match"))
                    .foregroundStyle(DJColor.foreground)
                Button("Apply \(pending.count)") { model.applyIdentity(pending.map(\.id)) }
                    .buttonStyle(.dj(.outline, size: .small))
                    .disabled(pending.allSatisfy { model.applying.contains($0.id) })
            }
            .djText(.caption)
            .frame(minHeight: 24)
        }
    }
}

// MARK: - Setup

/// Setup: ① Analyze's results, then Repair, Normalize and Stems as switches
/// with their options, the file type and Process. Starts from the last run's
/// recipe; Repair starts from the quality check's suggestion.
struct ProcessSetupCard: View {
    @Environment(AppModel.self) private var model
    let ids: [Track.ID]
    var started: () -> Void = {}
    @State private var recipe: ProcessRecipe

    init(ids: [Track.ID], initial: ProcessRecipe, started: @escaping () -> Void = {}) {
        self.ids = ids
        self.started = started
        _recipe = State(initialValue: initial)
    }

    var body: some View {
        let tracks = ids.compactMap(model.track)
        let repairOn = repairBinding(tracks).wrappedValue
        VStack(spacing: 0) {
            StepList {
                AnalyzeRow(tracks: tracks)
                StepRow(number: 2, mark: repairOn ? .on : .off, title: "Repair") {
                    repairDetail(tracks, on: repairOn)
                } trailing: {
                    Toggle("Repair", isOn: repairBinding(tracks)).toggleStyle(.djSwitch)
                }
                .help(repairHelp(tracks))
                StepRow(number: 3, mark: recipe.normalize ? .on : .off, title: "Normalize") {
                    NormalizeDetail(tracks: tracks, target: model.settings.loudnessTarget)
                } trailing: {
                    if recipe.normalize { TargetMenu() }
                    Toggle("Normalize", isOn: $recipe.normalize).toggleStyle(.djSwitch)
                }
                .task(id: ids) { model.measureLoudnessIfNeeded(Array(ids.prefix(12))) }
                StepRow(number: 4, mark: recipe.stems ? .on : .off, title: "Stems") {
                    EmptyView()
                } trailing: {
                    if recipe.stems {
                        StemModelMenu(selection: $recipe.stemModel)
                        StemKeepMenu(model: recipe.stemModel, choice: $recipe.stemChoice)
                    }
                    Toggle("Stems", isOn: $recipe.stems).toggleStyle(.djSwitch)
                }
            }
            StepFooter {
                FormatMenu(selection: $recipe.format)
                if repairOn, !recipe.format.isLossless {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(DJColor.marker)
                        .help("MP3 drops the highs Repair rebuilds. Lossless keeps them.")
                }
            } trailing: {
                let anyStep = repairOn || recipe.normalize || recipe.stems
                Button(tracks.count > 1 ? "Process \(tracks.count) Tracks" : "Process", systemImage: "play.fill") {
                    // An untouched Repair stays a suggestion, settled per track.
                    model.process(tracks.map(\.id), recipe: recipe)
                    started()
                }
                .buttonStyle(.dj(.primary))
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(!anyStep || !tracks.contains(where: \.fileExists))
                .help("⌘↩")
            }
        }
        .djCard()
    }

    private func repairBinding(_ tracks: [Track]) -> Binding<Bool> {
        let suggested = tracks.contains(where: \.needsRepair)
        return Binding(
            get: { recipe.repair == .on || (recipe.repair == .suggested && suggested) },
            set: { recipe.repair = $0 ? .on : .off }
        )
    }

    /// Where the highs stop; amber with a dot when the file is lossy and
    /// Repair is off.
    private func repairDetail(_ tracks: [Track], on: Bool) -> some View {
        let lossy = tracks.filter(\.needsRepair).count
        let flagged = lossy > 0 && !on
        return HStack(spacing: 5) {
            if flagged {
                Circle().fill(DJColor.marker).frame(width: 6, height: 6)
            }
            Text(repairText(tracks, lossy: lossy))
                .foregroundStyle(flagged ? DJColor.marker : DJColor.mutedForeground)
        }
    }

    private func repairText(_ tracks: [Track], lossy: Int) -> String {
        if tracks.count > 1 {
            if lossy > 0 { return "\(lossy) of \(tracks.count) lossy" }
            return tracks.contains { $0.verdict == nil && $0.qualityError == nil } ? "" : "None lossy"
        }
        guard let quality = tracks.first?.quality else { return "" }
        if quality.verdict == .lossless { return "Lossless" }
        if let cutoff = quality.cutoffHz { return "Cuts at \(DJFormat.kHz(cutoff))" }
        return ""
    }

    private func repairHelp(_ tracks: [Track]) -> String {
        var lines: [String] = []
        if model.apolloState != .ready { lines.append("The first repair downloads the model (66 MB).") }
        if tracks.contains(where: \.isVeryLowSource) { lines.append("Very low-quality source: results vary.") }
        return lines.joined(separator: " ")
    }
}

// MARK: - Processing

/// One track's run going through the steps: each waiting, running (with its
/// own bar), done or skipped, and Cancel.
struct ProcessRunCard: View {
    @Environment(AppModel.self) private var model
    let track: Track
    let job: Job

    var body: some View {
        VStack(spacing: 0) {
            StepList {
                AnalyzeRow(tracks: [track], compact: true)
                ForEach(Array(ProcessStep.allCases.enumerated()), id: \.element) { index, step in
                    let stage = job.stage(of: step)
                    StepRow(number: index + 2, mark: stage.mark, title: step.title) {
                        switch stage {
                        case .running: Text(job.stepLine)
                        case .skipped: Text("Skipped")
                        default: EmptyView()
                        }
                    } trailing: {
                        EmptyView()
                    } below: {
                        if stage == .running { StepBar(fraction: job.stepProgress) }
                    }
                }
            }
            StepFooter {
                Text(job.state == .queued ? "Waiting in line" : job.format?.shortTitle ?? "")
                    .djText(.caption)
                    .foregroundStyle(DJColor.mutedForeground)
            } trailing: {
                Button("Cancel") { model.cancel(job.id) }
                    .buttonStyle(.dj(.outline))
            }
        }
        .djCard()
    }
}

/// Several selected tracks while any of them runs: each one's step and bar,
/// and Cancel All.
struct ProcessRunList: View {
    @Environment(AppModel.self) private var model
    let tracks: [Track]

    var body: some View {
        VStack(spacing: 0) {
            ForEach(Array(tracks.enumerated()), id: \.element.id) { index, track in
                if index > 0 { DJDivider() }
                row(track, job: model.processJob(for: track.id))
            }
            StepFooter {
                let done = tracks.filter { model.processJob(for: $0.id)?.state == .finished }.count
                Text("\(done) of \(tracks.count) done")
                    .djText(.caption)
                    .foregroundStyle(DJColor.mutedForeground)
                    .monospacedDigit()
            } trailing: {
                Button("Cancel All") { model.cancelAll(tracks.map(\.id)) }
                    .buttonStyle(.dj(.outline))
            }
        }
        .djCard()
    }

    private func row(_ track: Track, job: Job?) -> some View {
        HStack(spacing: DJSpace.md) {
            FormatTile(container: track.container, size: 24)
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: DJSpace.sm) {
                    Text(track.name)
                        .djText(.bodyMedium)
                        .foregroundStyle(DJColor.foreground)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: DJSpace.md)
                    status(track, job: job)
                        .djText(.caption)
                        .monospacedDigit()
                        .lineLimit(1)
                }
                if let job, job.state == .running {
                    DJProgressBar(fraction: job.progress, height: 3, tint: DJColor.ring)
                }
            }
        }
        .padding(.horizontal, DJSpace.lg)
        .padding(.vertical, 9)
    }

    @ViewBuilder private func status(_ track: Track, job: Job?) -> some View {
        switch job?.state {
        case .queued: Text("Waiting in line").foregroundStyle(DJColor.mutedForeground)
        case .running: Text(job?.stepLine ?? "").foregroundStyle(DJColor.mutedForeground)
        case .finished:
            HStack(spacing: 3) {
                Image(systemName: "checkmark").font(.system(size: 9, weight: .bold))
                Text("Done")
            }
            .foregroundStyle(DJColor.success)
        case .failed(let message): Text("Failed").foregroundStyle(DJColor.destructive).help(message)
        case .cancelled: Text("Cancelled").foregroundStyle(DJColor.mutedForeground)
        case nil: EmptyView()
        }
    }
}

// MARK: - Done

/// What a finished run did, step by step, and Process Again.
struct ProcessDoneCard: View {
    let track: Track
    let files: ProcessedFiles
    var processAgain: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            StepList {
                AnalyzeRow(tracks: [track], compact: true)
                StepRow(number: 2, mark: files.repaired ? .done : .skipped, title: "Repair") {
                    if !files.repaired { Text("Skipped") }
                } trailing: { EmptyView() }
                StepRow(number: 3, mark: files.normalization == nil ? .skipped : .done, title: "Normalize") {
                    if let plan = files.normalization {
                        Text(DJFormat.lufs(plan.resultingLUFS)).help(plan.change)
                    } else {
                        Text("Skipped")
                    }
                } trailing: { EmptyView() }
                StepRow(number: 4, mark: files.stems?.isEmpty == false ? .done : .skipped, title: "Stems") {
                    if let stems = files.stems, !stems.isEmpty {
                        Text([DJFormat.count(stems.count, "stem"), files.stemModel?.title].compactMap { $0 }.joined(separator: " · "))
                    } else {
                        Text("Skipped")
                    }
                } trailing: { EmptyView() }
            }
            StepFooter {
                Text(format)
                    .djText(.caption)
                    .foregroundStyle(DJColor.mutedForeground)
            } trailing: {
                Button("Process Again", systemImage: "arrow.counterclockwise", action: processAgain)
                    .buttonStyle(.dj(.ghost, size: .small))
            }
        }
        .djCard()
    }

    /// "AIFF", from what was saved.
    private var format: String {
        let url = files.output ?? files.stems?.values.first
        return url.map { DJFormat.container($0.pathExtension) } ?? ""
    }
}

// MARK: - Options

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

