import AudioExport
import Foundation

/// One run of a tool on one track. Quality checks and Track ID are cheap and
/// run side by side; a Process run that only normalizes decodes the file and
/// runs two at a time; one that repairs or separates stems is heavy and runs
/// one at a time.
struct Job: Identifiable, Equatable, Sendable {
    enum Kind: Equatable, Sendable {
        case quality
        /// Track ID: Shazam + Apple Music. Light, network-bound.
        case identify
        /// Measure only (the Normalize row's readout); not shown in the queue.
        case loudness
        /// Repair → normalize to the target → stems, saved once.
        case process(ProcessRecipe, DJLoudnessTarget)

        var isHeavy: Bool {
            if case .process(let recipe, _) = self { return recipe.isHeavy }
            return false
        }

        /// Light jobs that decode the whole file: two at a time.
        var isDecoding: Bool {
            switch self {
            case .loudness: true
            case .process(let recipe, _): !recipe.isHeavy
            default: false
            }
        }

        /// Runs in the background for the UI; the queue only lists it while
        /// it runs or when it failed.
        var isBackground: Bool { self == .quality || self == .identify || self == .loudness }

        var title: String {
            switch self {
            case .quality: "Quality check"
            case .identify: "Track ID"
            case .loudness: "Loudness"
            case .process(let recipe, let target): recipe.title(target: target)
            }
        }

        var systemImage: String {
            switch self {
            case .quality: "waveform.badge.magnifyingglass"
            case .identify: "shazam.logo"
            case .loudness: "speaker.wave.2"
            case .process(let recipe, _):
                recipe.repair == .on ? "wand.and.stars" : recipe.stems && !recipe.normalize ? "square.3.layers.3d" : "speaker.wave.2"
            }
        }

        /// Same tool, any options.
        func sameTool(as other: Kind) -> Bool {
            switch (self, other) {
            case (.quality, .quality), (.identify, .identify), (.loudness, .loudness), (.process, .process): true
            default: false
            }
        }
    }

    enum State: Equatable, Sendable {
        case queued, running, finished, failed(String), cancelled

        var isActive: Bool { self == .queued || self == .running }
    }

    let id: UUID
    let trackID: Track.ID
    let trackName: String
    let kind: Kind
    /// The file type a Process run saves as (nil for checks and measuring).
    let format: AudioFileFormat?
    var state: State = .queued
    /// 0…1 while running, when the engine reports it.
    var progress: Double?
    var resultURL: URL?
    /// The engine's own status line while running (Apollo: "Loading model", …).
    var statusText: String?
    let createdAt: Date

    init(trackID: Track.ID, trackName: String, kind: Kind, format: AudioFileFormat? = nil,
         id: UUID = UUID(), createdAt: Date = Date()) {
        self.id = id
        self.trackID = trackID
        self.trackName = trackName
        self.kind = kind
        self.format = kind.isBackground ? nil : format
        self.createdAt = createdAt
    }

    /// "Repair · −10 LUFS · AIFF".
    var title: String {
        guard let format else { return kind.title }
        return "\(kind.title) · \(format.shortTitle)"
    }

    /// The row's status line: "Waiting", "Repairing · 42%", "Done", the error.
    var statusLine: String {
        switch state {
        case .queued: return "Waiting"
        case .running:
            let verb = switch kind {
            case .quality: "Checking"
            case .identify: "Listening"
            case .loudness: "Measuring"
            case .process: "Starting"
            }
            let label = statusText ?? verb
            return progress.map { "\(label) · \(DJFormat.percent($0))" } ?? "\(label)…"
        case .finished: return "Done"
        case .failed(let message): return message
        case .cancelled: return "Cancelled"
        }
    }
}
