import AudioExport
import Foundation

/// One run of a tool on one track. Quality checks are cheap and run side by
/// side; loudness measuring and normalizing decode the whole file and run two
/// at a time; stems and Apollo repairs are heavy and run one at a time.
struct Job: Identifiable, Equatable, Sendable {
    enum Kind: Equatable, Sendable {
        case quality
        /// Track ID: Shazam + Apple Music. Light, network-bound.
        case identify
        case stems(DJStemModel, DJStemChoice)
        case repair
        /// Measure only (for the Normalize card); not shown in the queue.
        case loudness
        /// Measure, then save a copy at the target loudness.
        case normalize(DJLoudnessTarget)

        var isHeavy: Bool {
            switch self {
            case .stems, .repair: true
            case .quality, .identify, .loudness, .normalize: false
            }
        }

        /// Light jobs that decode the whole file: two at a time.
        var isDecoding: Bool {
            switch self {
            case .loudness, .normalize: true
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
            case .stems(let model, _): "Stems · \(model.modelName)"
            case .repair: "Repair"
            case .loudness: "Loudness"
            case .normalize(let target): "Normalize to \(DJFormat.lufs(target.lufs, decimals: 0))"
            }
        }

        var systemImage: String {
            switch self {
            case .quality: "waveform.badge.magnifyingglass"
            case .identify: "shazam.logo"
            case .stems: "square.3.layers.3d"
            case .repair: "wand.and.stars"
            case .loudness, .normalize: "speaker.wave.2"
            }
        }

        /// Same tool, any stem model.
        func sameTool(as other: Kind) -> Bool {
            switch (self, other) {
            case (.quality, .quality), (.identify, .identify), (.repair, .repair), (.stems, .stems), (.loudness, .loudness),
                 (.normalize, .normalize): true
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
    /// The file type stems, repairs and normalized copies are saved as
    /// (nil for quality checks and measuring).
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

    /// "Stems · htdemucs · AIFF", "Repair · MP3 320".
    var title: String {
        guard let format else { return kind.title }
        return "\(kind.title) · \(format.shortTitle)"
    }

    /// The row's status line: "Queued", "Separating · 42%", "Done", the error.
    var statusLine: String {
        switch state {
        case .queued: return "Waiting"
        case .running:
            let verb = switch kind {
            case .quality: "Checking"
            case .identify: "Listening"
            case .stems: "Separating"
            case .repair: "Repairing"
            case .loudness: "Measuring"
            case .normalize: "Normalizing"
            }
            let label = statusText ?? verb
            return progress.map { "\(label) · \(DJFormat.percent($0))" } ?? "\(label)…"
        case .finished: return "Done"
        case .failed(let message): return message
        case .cancelled: return "Cancelled"
        }
    }
}
