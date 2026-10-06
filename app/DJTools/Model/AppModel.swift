import AudioExport
import Foundation
import Observation

struct AppError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

/// Asks for Apollo's one-time setup before repairing these tracks.
struct ApolloSetupRequest: Identifiable, Equatable {
    let id = UUID()
    var trackIDs: [Track.ID]
}

/// The app's state: dropped tracks, the job queue and Apollo's setup.
///
/// Jobs: quality checks start straight away, up to `maxConcurrentChecks`
/// at once; Track ID and BPM / key detection each have their own limit.
/// Loudness measuring and normalize-only Process runs decode the
/// whole file but need little memory: up to `maxConcurrentDecodes` at once,
/// beside everything else. A Process run that repairs or separates is heavy
/// (Apollo and Demucs each peak around 3–6 GB, one after the other inside the
/// run) and runs strictly one at a time, in the order asked for:
/// `heavyInFlight` is a single slot only released when the job's task has
/// returned, so a cancelled job still holds it until its engine has stopped.
@MainActor
@Observable
final class AppModel {
    private(set) var tracks: [Track] = []
    private(set) var jobs: [Job] = []
    private(set) var apolloState: DJApolloSetupState = .notInstalled
    /// Drives the Apollo setup sheet.
    var apolloSetup: ApolloSetupRequest?
    /// A one-line message for the window ("Nothing to add…").
    var notice: String?

    let settings: AppSettings
    let engines: Engines

    static let maxConcurrentChecks = 4
    static let maxConcurrentDecodes = 2
    /// Track ID lookups at once (network-bound; Apple throttles bursts).
    static let maxConcurrentIdentify = 2
    /// BPM / key detections at once (a decode and the tempo model on the GPU each).
    static let maxConcurrentAnalyses = 2

    /// The tempo model is downloaded (Settings ▸ Analysis).
    private(set) var analysisModelReady = false

    /// Tracks whose Track ID match is being written right now.
    private(set) var applying: Set<Track.ID> = []

    @ObservationIgnored private let store: LibraryStore?
    @ObservationIgnored private var tasks: [Job.ID: Task<Void, Never>] = [:]
    /// The heavy job whose task is still running (it may already read as
    /// cancelled while its engine winds down).
    @ObservationIgnored private var heavyInFlight: Job.ID?
    /// Process runs waiting for Apollo's setup to finish.
    @ObservationIgnored private var pendingProcess: [(id: Track.ID, recipe: ProcessRecipe, target: DJLoudnessTarget)] = []

    init(engines: Engines, settings: AppSettings, store: LibraryStore?) {
        self.engines = engines
        self.settings = settings
        self.store = store
        tracks = store?.load() ?? []
        Task { await refreshApolloState() }
        // Checks that never finished (the app quit mid-way) run again.
        let unchecked = tracks.filter { $0.quality == nil && $0.fileExists }.map(\.id)
        if !unchecked.isEmpty { checkQuality(unchecked) }
    }

    // MARK: - Tracks

    func track(_ id: Track.ID) -> Track? {
        tracks.first { $0.id == id }
    }

    /// Adds dropped files and folders (searched recursively for supported
    /// audio), skipping ones already in the list, and checks each one's
    /// quality. Returns the new tracks' IDs.
    @discardableResult
    func add(_ urls: [URL]) -> [Track.ID] {
        let known = Set(tracks.map { $0.url.standardizedFileURL.path })
        var seen = known
        var added: [Track] = []
        for url in Self.audioFiles(in: urls) {
            let path = url.standardizedFileURL.path
            guard !seen.contains(path) else { continue }
            seen.insert(path)
            added.append(Track(url: url))
        }
        if added.isEmpty {
            if !urls.isEmpty {
                notice = Self.audioFiles(in: urls).isEmpty
                    ? "Nothing to add: DJ Tools reads MP3, M4A, FLAC, WAV and AIFF."
                    : "Those tracks are already in the list."
            }
            return []
        }
        tracks.append(contentsOf: added)
        save()
        checkQuality(added.map(\.id))
        if settings.identifyOnAdd { identify(added.map(\.id)) }
        analyzeIfNeeded(added.map(\.id))
        return added.map(\.id)
    }

    /// Audio files among `urls`, folders expanded, sorted by name within each folder.
    nonisolated static func audioFiles(in urls: [URL]) -> [URL] {
        var files: [URL] = []
        for url in urls {
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else { continue }
            if isDirectory.boolValue {
                let enumerator = FileManager.default.enumerator(
                    at: url, includingPropertiesForKeys: [.isRegularFileKey],
                    options: [.skipsHiddenFiles, .skipsPackageDescendants]
                )
                var found: [URL] = []
                while let next = enumerator?.nextObject() as? URL {
                    if Track.supportedExtensions.contains(next.pathExtension.lowercased()) { found.append(next) }
                }
                files += found.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
            } else if Track.supportedExtensions.contains(url.pathExtension.lowercased()) {
                files.append(url)
            }
        }
        return files
    }

    /// Removes tracks from the list (their files and results stay on disk)
    /// and cancels their jobs.
    func remove(_ ids: Set<Track.ID>) {
        for job in jobs where ids.contains(job.trackID) && job.state.isActive {
            cancel(job.id)
        }
        tracks.removeAll { ids.contains($0.id) }
        jobs.removeAll { ids.contains($0.trackID) && !$0.state.isActive }
        pendingProcess.removeAll { ids.contains($0.id) }
        save()
    }

    private func updateTrack(_ id: Track.ID, _ change: (inout Track) -> Void) {
        guard let index = tracks.firstIndex(where: { $0.id == id }) else { return }
        change(&tracks[index])
        save()
    }

    private func save() {
        store?.save(tracks)
    }

    // MARK: - Actions

    func checkQuality(_ ids: [Track.ID]) {
        for id in ids {
            updateTrack(id) { $0.qualityError = nil }
            enqueue(.quality, for: id)
        }
    }

    // MARK: - Track ID

    /// Listens to each track with Shazam and looks it up in Apple Music.
    /// The match waits for Apply (or is applied straight away, when
    /// Settings says so and it's a sure one).
    func identify(_ ids: [Track.ID]) {
        for id in ids {
            updateTrack(id) { $0.identifyError = nil }
            enqueue(.identify, for: id)
        }
    }

    /// Writes each track's match into its file (no re-encoding; other tags
    /// stay), with the detected BPM and key where the file has none (after
    /// a pending detection), and, when Settings says so, renames it
    /// "Artist - Title.ext" in its folder. Do this before importing into
    /// Rekordbox: it finds tracks by path.
    func applyIdentity(_ ids: [Track.ID]) {
        let targets = ids.filter { id in
            guard let track = track(id) else { return false }
            return track.identity != nil && track.fileExists && !applying.contains(id)
        }
        guard !targets.isEmpty else { return }
        // Before `applying`: analyzeIfNeeded skips tracks being written.
        analyzeIfNeeded(targets)
        applying.formUnion(targets)
        let rename = settings.renameOnApply
        Task {
            var failures: [String] = []
            for id in targets {
                defer { applying.remove(id) }
                try? await waitForAnalysis(id)
                guard let track = track(id), let identity = track.identity else { continue }
                do {
                    let existing = await AudioTags.read(from: track.url)
                    let tags = TrackTags.fillingAnalysis(
                        await TrackTags.tags(for: identity), from: track, keyTag: settings.keyTag, existing: existing)
                    var destination: URL?
                    if rename {
                        let name = TrackTags.fileName(TrackTags.displayName(tags, fallback: track.name))
                        let candidate = track.url.deletingLastPathComponent().appending(path: "\(name).\(track.url.pathExtension)")
                        if candidate.standardizedFileURL.path != track.url.standardizedFileURL.path {
                            destination = Self.unique(candidate)
                        }
                    }
                    let url = try await AudioRetagger.retag(track.url, with: tags, moveTo: destination)
                    let written = await AudioTags.read(from: url)
                    updateTrack(id) {
                        $0.url = url
                        if $0.analysis != nil {
                            // The file's own genre still counts for folding after the match's replaced it.
                            var tags = FileMusicalTags(written)
                            tags.genre = $0.fileTags?.genre ?? existing.genre
                            $0.fileTags = tags
                        }
                        $0.fileSize = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init)
                        $0.identityStatus = .applied
                    }
                } catch {
                    failures.append("\(track.name): \(error.localizedDescription)")
                }
            }
            if !failures.isEmpty {
                notice = "Couldn't write the tags. " + failures.joined(separator: " · ")
            }
        }
    }

    /// "Not This Track": the match is kept out of the tags and names.
    func dismissIdentity(_ ids: [Track.ID]) {
        for id in ids { updateTrack(id) { $0.identityStatus = .dismissed } }
    }

    /// Runs `recipe` on each track: repair → normalize → stems, saved once.
    /// Remembers it for next time (Repair goes back to the suggestion). When
    /// a track will be repaired and Apollo isn't set up, asks for that first.
    func process(_ ids: [Track.ID], recipe: ProcessRecipe) {
        var remembered = recipe
        remembered.repair = .suggested
        settings.lastRecipe = remembered
        let target = settings.loudnessTarget
        let runs = ids.compactMap { id in track(id).map { (id: id, recipe: recipe.resolved(for: $0), target: target) } }
        guard !runs.isEmpty else { return }
        let needsApollo = runs.contains { $0.recipe.repair != .off }
        if needsApollo, apolloState != .ready {
            pendingProcess.removeAll { run in runs.contains { $0.id == run.id } }
            pendingProcess += runs
            apolloSetup = ApolloSetupRequest(trackIDs: pendingProcess.map(\.id))
            return
        }
        for run in runs { enqueue(.process(run.recipe, run.target), for: run.id, format: run.recipe.format) }
    }

    /// Measures loudness for the Normalize row, once per track (not again
    /// after a failure until asked).
    func measureLoudnessIfNeeded(_ ids: [Track.ID]) {
        for id in ids {
            guard let track = track(id), track.loudness == nil, track.loudnessError == nil, track.fileExists,
                  job(for: id, kind: .loudness)?.state.isActive != true
            else { continue }
            enqueue(.loudness, for: id)
        }
    }

    func measureLoudnessAgain(_ id: Track.ID) {
        updateTrack(id) { $0.loudness = nil; $0.loudnessError = nil }
        enqueue(.loudness, for: id)
    }

    /// BPM and key for the Analyze row and the tags, once per track (not
    /// again after a failure until asked), when Settings says so.
    ///
    /// A model that couldn't be set up (offline) fails only that job: the
    /// next trigger (showing the track, Process, Apply, Try Again, relaunch)
    /// tries again, nothing retries by itself.
    func analyzeIfNeeded(_ ids: [Track.ID]) {
        guard settings.detectBPMKey else { return }
        for id in ids {
            guard let track = track(id), track.analysis == nil, track.analysisError == nil, track.fileExists,
                  !applying.contains(id), job(for: id, kind: .analyze)?.state.isActive != true
            else { continue }
            enqueue(.analyze, for: id)
        }
    }

    /// Detects BPM and key again after a failure (not while its tags are
    /// being written).
    func analyze(_ ids: [Track.ID]) {
        for id in ids where !applying.contains(id) {
            updateTrack(id) { $0.analysisError = nil }
            enqueue(.analyze, for: id)
        }
    }

    // MARK: - Jobs

    /// The active (or last) job of a tool for a track.
    func job(for trackID: Track.ID, kind: Job.Kind) -> Job? {
        jobs.last { $0.trackID == trackID && $0.kind.sameTool(as: kind) }
    }

    var activeJobCount: Int { jobs.filter(\.state.isActive).count }

    /// A track's latest Process run (active, finished, failed or cancelled).
    func processJob(for trackID: Track.ID) -> Job? {
        jobs.last { $0.trackID == trackID && $0.kind.isProcess }
    }

    /// Where a track stands: being processed (queued or running), done (its
    /// latest result is there and no run since failed), or ready.
    func stage(of track: Track) -> TrackStage {
        if let job = processJob(for: track.id) {
            if job.state.isActive { return .processing }
            if job.state.isUnsuccessful { return .ready }
        }
        return track.latestFiles == nil ? .ready : .done
    }

    func cancel(_ id: Job.ID) {
        guard let index = jobs.firstIndex(where: { $0.id == id }), jobs[index].state.isActive else { return }
        let wasRunning = jobs[index].state == .running
        jobs[index].state = .cancelled
        jobs[index].progress = nil
        if wasRunning {
            tasks[id]?.cancel()
            if case .process(let recipe, _) = jobs[index].kind, recipe.repair != .off {
                let apollo = engines.apollo
                Task { await apollo.cancel() }
            }
        }
        pump()
    }

    /// The sidebar's groups in order (Processing, Ready, Done), empty ones left out.
    var trackGroups: [(stage: TrackStage, tracks: [Track])] {
        let staged = tracks.map { (track: $0, stage: stage(of: $0)) }
        return [TrackStage.processing, .ready, .done].compactMap { stage in
            let members = staged.filter { $0.stage == stage }.map(\.track)
            return members.isEmpty ? nil : (stage, members)
        }
    }

    /// Cancels every active job, or only the Process runs of `trackIDs`.
    func cancelAll(_ trackIDs: [Track.ID]? = nil) {
        for job in jobs where job.state.isActive {
            if let trackIDs {
                guard trackIDs.contains(job.trackID), job.kind.isProcess else { continue }
            }
            cancel(job.id)
        }
    }

    /// Forgets a failed or cancelled run (its notice in the detail pane).
    func dismissJob(_ id: Job.ID) {
        jobs.removeAll { $0.id == id && !$0.state.isActive }
    }

    private func enqueue(_ kind: Job.Kind, for trackID: Track.ID, format: AudioFileFormat? = nil) {
        guard let track = track(trackID) else { return }
        // Once per tool per track at a time.
        if jobs.contains(where: { $0.trackID == trackID && $0.kind.sameTool(as: kind) && $0.state.isActive }) { return }
        // Drop older finished runs of the same tool for this track.
        jobs.removeAll { $0.trackID == trackID && $0.kind.sameTool(as: kind) && !$0.state.isActive }
        jobs.append(Job(trackID: trackID, trackName: track.name, kind: kind, format: format))
        pump()
    }

    /// Starts what can start: checks and decodes up to their limits, one heavy job.
    private func pump() {
        #if DEBUG
        if isFixture { return }
        #endif
        let runningChecks = jobs.filter { $0.kind == .quality && $0.state == .running }.count
        for job in jobs.filter({ $0.kind == .quality && $0.state == .queued }).prefix(max(0, Self.maxConcurrentChecks - runningChecks)) {
            start(job.id)
        }
        let runningIDs = jobs.filter { $0.kind == .identify && $0.state == .running }.count
        for job in jobs.filter({ $0.kind == .identify && $0.state == .queued }).prefix(max(0, Self.maxConcurrentIdentify - runningIDs)) {
            start(job.id)
        }
        let runningAnalyses = jobs.filter { $0.kind == .analyze && $0.state == .running }.count
        for job in jobs.filter({ $0.kind == .analyze && $0.state == .queued }).prefix(max(0, Self.maxConcurrentAnalyses - runningAnalyses)) {
            start(job.id)
        }
        let runningDecodes = jobs.filter { $0.kind.isDecoding && $0.state == .running }.count
        for job in jobs.filter({ $0.kind.isDecoding && $0.state == .queued }).prefix(max(0, Self.maxConcurrentDecodes - runningDecodes)) {
            start(job.id)
        }
        if heavyInFlight == nil, let next = jobs.first(where: { $0.kind.isHeavy && $0.state == .queued }) {
            heavyInFlight = next.id
            start(next.id)
        }
    }

    private func start(_ id: Job.ID) {
        guard let index = jobs.firstIndex(where: { $0.id == id }) else { return }
        jobs[index].state = .running
        jobs[index].progress = jobs[index].kind == .quality ? nil : 0
        let job = jobs[index]
        tasks[id] = Task { await self.run(job) }
    }

    private func isRunning(_ id: Job.ID) -> Bool {
        jobs.first { $0.id == id }?.state == .running
    }

    private func setProgress(_ id: Job.ID, _ fraction: Double) {
        guard let index = jobs.firstIndex(where: { $0.id == id }), jobs[index].state == .running else { return }
        jobs[index].progress = fraction
    }

    /// Moves a Process run's stepper on; a late update for an earlier step is dropped.
    private func setStep(_ id: Job.ID, _ step: ProcessStep, _ fraction: Double) {
        guard let index = jobs.firstIndex(where: { $0.id == id }), jobs[index].state == .running else { return }
        let steps = jobs[index].steps
        if let current = jobs[index].currentStep, current != step,
           let from = steps.firstIndex(of: current), let to = steps.firstIndex(of: step), to < from { return }
        if jobs[index].currentStep != step { jobs[index].statusText = nil }
        jobs[index].currentStep = step
        jobs[index].stepProgress = fraction
    }

    private func setSteps(_ id: Job.ID, _ steps: [ProcessStep]) {
        guard let index = jobs.firstIndex(where: { $0.id == id }), jobs[index].state == .running else { return }
        jobs[index].steps = steps
    }

    private func setStatus(_ id: Job.ID, _ text: String) {
        guard let index = jobs.firstIndex(where: { $0.id == id }), jobs[index].state == .running else { return }
        jobs[index].statusText = text
    }

    private func finish(_ id: Job.ID, _ state: Job.State, result: URL? = nil) {
        guard let index = jobs.firstIndex(where: { $0.id == id }), jobs[index].state == .running else { return }
        jobs[index].state = state
        jobs[index].resultURL = result
        jobs[index].statusText = nil
        if state == .finished { jobs[index].progress = 1 }
    }

    private func run(_ job: Job) async {
        defer {
            tasks[job.id] = nil
            if heavyInFlight == job.id { heavyInFlight = nil }
            pump()
        }
        guard let track = track(job.trackID) else {
            finish(job.id, .failed("The track was removed."))
            return
        }
        let progress: @Sendable (Double) -> Void = { [weak self] fraction in
            Task { @MainActor in self?.setProgress(job.id, fraction) }
        }
        let status: @Sendable (String) -> Void = { [weak self] line in
            Task { @MainActor in self?.setStatus(job.id, line) }
        }
        let step: @Sendable (ProcessStep, Double) -> Void = { [weak self] current, fraction in
            Task { @MainActor in self?.setStep(job.id, current, fraction) }
        }
        do {
            guard track.fileExists else { throw AppError("Can't find the file. It may have moved.") }
            switch job.kind {
            case .quality:
                let report = try await engines.quality.analyze(track.url)
                guard isRunning(job.id) else { return }
                updateTrack(track.id) { $0.quality = report; $0.qualityError = nil }
                finish(job.id, .finished)

            case .identify:
                let identity = try await engines.identifier.identify(track.url, progress: progress)
                guard isRunning(job.id) else { return }
                updateTrack(track.id) {
                    $0.identity = identity
                    $0.identifiedAt = Date()
                    $0.identityStatus = nil
                    $0.identifyError = nil
                }
                finish(job.id, .finished)
                if settings.autoApplyMatches, let updated = self.track(track.id),
                   updated.identity?.isStrong == true, !updated.identityLengthMismatch {
                    applyIdentity([track.id])
                }

            case .loudness:
                let report = try await engines.loudness.measure(track.url, progress: progress)
                guard isRunning(job.id) else { return }
                updateTrack(track.id) { $0.loudness = report; $0.loudnessError = nil }
                finish(job.id, .finished)

            case .analyze:
                let analysis = try await engines.analyzer.analyze(track.url, progress: progress, status: status)
                let tags = await AudioTags.read(from: track.url)
                guard isRunning(job.id) else { return }
                analysisModelReady = true
                updateTrack(track.id) {
                    $0.analysis = analysis
                    $0.analysisError = nil
                    $0.fileTags = FileMusicalTags(tags)
                }
                finish(job.id, .finished)

            case .process(let recipe, let target):
                // The name and the repair suggestion come from Track ID and
                // the quality check: let this track's finish first.
                try await waitForChecks(track.id)
                // BPM and key go into the tags where the file has none.
                analyzeIfNeeded([track.id])
                try await waitForAnalysis(track.id)
                guard let current = self.track(track.id), isRunning(job.id) else { return }
                let steps = ResultWriter.Steps(
                    repair: recipe.repairs(current),
                    normalize: recipe.normalize ? target : nil,
                    stems: recipe.stems ? (recipe.stemModel, recipe.stemChoice) : nil
                )
                guard !steps.isEmpty else { throw AppError("Nothing to do: no step is on.") }
                if steps.repair, apolloState != .ready { throw AppError("Repair isn't set up yet.") }
                setSteps(job.id, steps.order)
                let processed = try await ResultWriter.process(
                    input: current.url, steps: steps, format: job.format ?? recipe.format,
                    tags: await resultTags(current), outputFolder: try outputFolder(), engines: engines,
                    progress: progress, step: step, status: status
                )
                guard isRunning(job.id) else { return }
                updateTrack(track.id) {
                    // Only the original's own measurement describes the original.
                    if !steps.repair, let report = processed.loudness { $0.loudness = report; $0.loudnessError = nil }
                    $0.results.append(TrackResult(kind: .processed(processed.files)))
                }
                finish(job.id, .finished, result: processed.files.output ?? processed.files.stemsFolder)
            }
        } catch is CancellationError {
            finish(job.id, .cancelled)
        } catch {
            guard isRunning(job.id) else { return }
            let message = error.localizedDescription
            if job.kind == .quality { updateTrack(track.id) { $0.qualityError = message } }
            if job.kind == .loudness { updateTrack(track.id) { $0.loudnessError = message } }
            if job.kind == .identify { updateTrack(track.id) { $0.identifyError = message } }
            if job.kind == .analyze {
                if error is DJAnalysisModelUnavailable {
                    // Not the file's fault: the others queued now would fail the same way.
                    jobs.removeAll { $0.kind == .analyze && $0.state == .queued }
                } else {
                    updateTrack(track.id) { $0.analysisError = message }
                }
            }
            finish(job.id, .failed(message))
        }
    }

    /// Waits while this track's quality check or Track ID is queued or
    /// running, or its match is being written (that can rename the file).
    private func waitForChecks(_ id: Track.ID) async throws {
        while applying.contains(id)
            || jobs.contains(where: { $0.trackID == id && ($0.kind == .quality || $0.kind == .identify) && $0.state.isActive }) {
            try await Task.sleep(for: .milliseconds(250))
        }
    }

    /// Waits for this track's BPM / key detection when one is queued (it
    /// starts straight away, ahead of the line) or running.
    private func waitForAnalysis(_ id: Track.ID) async throws {
        if let job = job(for: id, kind: .analyze), job.state == .queued { start(job.id) }
        while job(for: id, kind: .analyze)?.state.isActive == true {
            try await Task.sleep(for: .milliseconds(250))
        }
    }

    /// A Process run's tags: the file's and the match (`TrackTags.forResults`),
    /// plus the detected BPM and key where the file has none.
    private func resultTags(_ track: Track) async -> AudioTags {
        let tags = await TrackTags.forResults(track)
        return TrackTags.fillingAnalysis(tags, from: track, keyTag: settings.keyTag, existing: tags)
    }

    private func outputFolder() throws -> URL {
        let folder = settings.outputFolder
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    /// `name.aiff`, or `name 2.aiff`, `name 3.aiff`… when taken.
    nonisolated static func unique(_ url: URL) -> URL {
        guard FileManager.default.fileExists(atPath: url.path) else { return url }
        let base = url.deletingPathExtension().lastPathComponent, ext = url.pathExtension
        let folder = url.deletingLastPathComponent()
        var n = 2
        while true {
            let candidate = folder.appending(path: "\(base) \(n).\(ext)")
            if !FileManager.default.fileExists(atPath: candidate.path) { return candidate }
            n += 1
        }
    }

    // MARK: - Apollo setup

    func refreshApolloState() async {
        let state = await engines.apollo.state()
        // An install started meanwhile reports its own lines.
        if !apolloState.isInstalling || !state.isInstalling { apolloState = state }
    }

    /// The setup sheet's Install: downloads the model, then runs the
    /// repairs that were waiting for it and closes the sheet.
    func installApollo() {
        guard !apolloState.isInstalling else { return }
        apolloState = .installing("Starting…")
        let apollo = engines.apollo
        Task {
            do {
                try await apollo.install { line in
                    Task { @MainActor in
                        guard self.apolloState.isInstalling else { return }
                        self.apolloState = .installing(line)
                    }
                }
                apolloState = await apollo.state()
            } catch {
                apolloState = .failed(error.localizedDescription)
                return
            }
            guard apolloState == .ready else { return }
            let waiting = pendingProcess
            pendingProcess = []
            apolloSetup = nil
            for run in waiting where track(run.id) != nil {
                enqueue(.process(run.recipe, run.target), for: run.id, format: run.recipe.format)
            }
        }
    }

    /// Settings ▸ Remove Apollo Model: stops repairs and deletes the weights.
    func resetApollo() async {
        for job in jobs where job.state.isActive {
            if case .process(let recipe, _) = job.kind, recipe.repair != .off { cancel(job.id) }
        }
        do {
            try await engines.apollo.reset()
        } catch {
            notice = "Couldn't remove the repair model: \(error.localizedDescription)"
        }
        apolloState = await engines.apollo.state()
    }

    // MARK: - Analysis model

    func refreshAnalysisModel() async {
        analysisModelReady = await engines.analyzer.isPrepared()
    }

    /// Settings ▸ Analysis ▸ Remove Model: stops detections and deletes the tempo model.
    func removeAnalysisModel() async {
        for job in jobs where job.state.isActive && job.kind == .analyze { cancel(job.id) }
        do {
            try await engines.analyzer.removeModel()
        } catch {
            notice = "Couldn't remove the tempo model: \(error.localizedDescription)"
        }
        await refreshAnalysisModel()
    }

    func dismissApolloSetup() {
        apolloSetup = nil
        // Not installing: the waiting repairs are dropped with the sheet.
        if !apolloState.isInstalling { pendingProcess = [] }
    }

    #if DEBUG
    /// Fixture state for `-renderPreviews` (no tasks, nothing saved).
    @ObservationIgnored private var isFixture = false

    func installFixture(tracks: [Track], jobs: [Job], apolloState: DJApolloSetupState) {
        // Nothing starts: the fixture's jobs stay as they are drawn.
        isFixture = true
        self.tracks = tracks
        self.jobs = jobs
        self.apolloState = apolloState
    }
    #endif
}
