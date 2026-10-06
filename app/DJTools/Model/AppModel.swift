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
/// at once. Stems and Apollo repairs are heavy (each peaks around 6 GB) and
/// run strictly one at a time *across both kinds*, in the order they were
/// asked for: `heavyInFlight` is a single slot shared by every heavy job and
/// is only released when the job's task has returned, so a cancelled job
/// still holds it until its engine has actually stopped.
@MainActor
@Observable
final class AppModel {
    private(set) var tracks: [Track] = []
    private(set) var jobs: [Job] = []
    private(set) var apolloState: DJApolloSetupState = .notInstalled
    /// Drives the Apollo setup sheet.
    var apolloSetup: ApolloSetupRequest?
    /// The job queue panel at the window's right edge.
    var isShowingJobs = false
    /// A one-line message for the window ("Nothing to add…").
    var notice: String?

    let settings: AppSettings
    let engines: Engines

    static let maxConcurrentChecks = 4

    @ObservationIgnored private let store: LibraryStore?
    @ObservationIgnored private var tasks: [Job.ID: Task<Void, Never>] = [:]
    /// The heavy job whose task is still running (it may already read as
    /// cancelled while its engine winds down).
    @ObservationIgnored private var heavyInFlight: Job.ID?
    /// Repairs waiting for Apollo's setup to finish, and the file type they asked for.
    @ObservationIgnored private var pendingRepairs: [Track.ID] = []
    @ObservationIgnored private var pendingRepairFormat: AudioFileFormat?

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
        pendingRepairs.removeAll { ids.contains($0) }
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

    /// Separates stems, saved as `format` (Settings' choice when nil).
    func separateStems(_ ids: [Track.ID], model: DJStemModel, format: AudioFileFormat? = nil) {
        let format = format ?? settings.stemsFormat
        for id in ids { enqueue(.stems(model), for: id, format: format) }
        if !ids.isEmpty { isShowingJobs = true }
    }

    /// Repairs with Apollo, saved as `format` (Settings' choice when nil), or
    /// first asks to set Apollo up.
    func repair(_ ids: [Track.ID], format: AudioFileFormat? = nil) {
        guard !ids.isEmpty else { return }
        let format = format ?? settings.repairFormat
        switch apolloState {
        case .ready:
            for id in ids { enqueue(.repair, for: id, format: format) }
            isShowingJobs = true
        case .installing:
            pendingRepairs.append(contentsOf: ids.filter { !pendingRepairs.contains($0) })
            pendingRepairFormat = format
            apolloSetup = ApolloSetupRequest(trackIDs: pendingRepairs)
        case .notInstalled, .failed:
            pendingRepairs = ids
            pendingRepairFormat = format
            apolloSetup = ApolloSetupRequest(trackIDs: ids)
        }
    }

    // MARK: - Jobs

    /// The active (or last) job of a tool for a track.
    func job(for trackID: Track.ID, kind: Job.Kind) -> Job? {
        jobs.last { $0.trackID == trackID && $0.kind.sameTool(as: kind) }
    }

    /// The running or queued job shown on a track's sidebar row: heavy first.
    func activeJob(for trackID: Track.ID) -> Job? {
        let active = jobs.filter { $0.trackID == trackID && $0.state.isActive }
        return active.first { $0.kind.isHeavy && $0.state == .running }
            ?? active.first { $0.state == .running }
            ?? active.first
    }

    var activeJobCount: Int { jobs.filter(\.state.isActive).count }
    var activeHeavyJobs: [Job] { jobs.filter { $0.kind.isHeavy && $0.state.isActive } }
    var runningHeavyJob: Job? { jobs.first { $0.kind.isHeavy && $0.state == .running } }

    /// What the queue panel lists: heavy jobs, and quality checks only while
    /// they run or when they failed (a dropped folder would bury the rest).
    var visibleJobs: [Job] {
        jobs.filter { job in
            job.kind.isHeavy || job.state == .running || { if case .failed = job.state { return true } else { return false } }()
        }
    }

    func cancel(_ id: Job.ID) {
        guard let index = jobs.firstIndex(where: { $0.id == id }), jobs[index].state.isActive else { return }
        let wasRunning = jobs[index].state == .running
        jobs[index].state = .cancelled
        jobs[index].progress = nil
        if wasRunning {
            tasks[id]?.cancel()
            if jobs[index].kind == .repair {
                let apollo = engines.apollo
                Task { await apollo.cancel() }
            }
        }
        pump()
    }

    func cancelAll() {
        for job in jobs where job.state.isActive { cancel(job.id) }
    }

    func clearFinishedJobs() {
        jobs.removeAll { !$0.state.isActive }
    }

    func retry(_ id: Job.ID) {
        guard let job = jobs.first(where: { $0.id == id }) else { return }
        jobs.removeAll { $0.id == id }
        switch job.kind {
        case .repair: repair([job.trackID], format: job.format)
        case .quality: checkQuality([job.trackID])
        case .stems: enqueue(job.kind, for: job.trackID, format: job.format)
        }
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

    /// Starts what can start: checks up to the limit, one heavy job.
    private func pump() {
        let runningChecks = jobs.filter { $0.kind == .quality && $0.state == .running }.count
        for job in jobs.filter({ $0.kind == .quality && $0.state == .queued }).prefix(max(0, Self.maxConcurrentChecks - runningChecks)) {
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
        jobs[index].progress = jobs[index].kind.isHeavy ? 0 : nil
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
        do {
            guard track.fileExists else { throw AppError("Can't find the file. It may have moved.") }
            switch job.kind {
            case .quality:
                let report = try await engines.quality.analyze(track.url)
                guard isRunning(job.id) else { return }
                updateTrack(track.id) { $0.quality = report; $0.qualityError = nil }
                finish(job.id, .finished)

            case .stems(let model):
                let output = try outputFolder()
                let result = try await ResultWriter.separate(
                    input: track.url, model: model, format: job.format ?? settings.stemsFormat,
                    outputFolder: output, engine: engines.stems, progress: progress, status: status
                )
                guard isRunning(job.id) else { return }
                let folder = result.stems.values.first?.deletingLastPathComponent()
                    ?? output.appending(path: "\(track.name) (Stems)", directoryHint: .isDirectory)
                updateTrack(track.id) {
                    $0.results.append(TrackResult(kind: .stems(model: model, folder: folder, stems: result.stems)))
                }
                finish(job.id, .finished, result: folder)

            case .repair:
                let written = try await ResultWriter.repair(
                    input: track.url, format: job.format ?? settings.repairFormat,
                    outputFolder: try outputFolder(), engine: engines.apollo, progress: progress, status: status
                )
                guard isRunning(job.id) else { return }
                updateTrack(track.id) { $0.results.append(TrackResult(kind: .repaired(output: written))) }
                finish(job.id, .finished, result: written)
            }
        } catch is CancellationError {
            finish(job.id, .cancelled)
        } catch {
            guard isRunning(job.id) else { return }
            let message = error.localizedDescription
            if job.kind == .quality { updateTrack(track.id) { $0.qualityError = message } }
            finish(job.id, .failed(message))
        }
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

    /// The setup sheet's Install: downloads the runtime, then runs the
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
            let waiting = pendingRepairs, format = pendingRepairFormat
            pendingRepairs = []
            pendingRepairFormat = nil
            apolloSetup = nil
            repair(waiting.filter { track($0) != nil }, format: format)
        }
    }

    /// Settings ▸ Reset Apollo Runtime: stops repairs and removes the runtime.
    func resetApollo() async {
        for job in jobs where job.kind == .repair && job.state.isActive { cancel(job.id) }
        do {
            try await engines.apollo.reset()
        } catch {
            notice = "Couldn't reset Apollo: \(error.localizedDescription)"
        }
        apolloState = await engines.apollo.state()
    }

    func dismissApolloSetup() {
        apolloSetup = nil
        // Not installing: the waiting repairs are dropped with the sheet.
        if !apolloState.isInstalling { pendingRepairs = [] }
    }

    #if DEBUG
    /// Fixture state for `-renderPreviews` (no tasks, nothing saved).
    func installFixture(tracks: [Track], jobs: [Job], apolloState: DJApolloSetupState, showsJobs: Bool = false) {
        self.tracks = tracks
        self.jobs = jobs
        self.apolloState = apolloState
        isShowingJobs = showsJobs
    }
    #endif
}
