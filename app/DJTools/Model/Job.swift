import Foundation

/// One run of a tool on one track. Quality checks are cheap and run side by
/// side; stems and Apollo repairs are heavy and run one at a time.
struct Job: Identifiable, Equatable, Sendable {
    enum Kind: Equatable, Sendable {
        case quality
        case stems(DJStemModel)
        case repair

        var isHeavy: Bool { self != .quality }

        var title: String {
            switch self {
            case .quality: "Quality check"
            case .stems(let model): "Stems · \(model.modelName)"
            case .repair: "Apollo repair"
            }
        }

        var systemImage: String {
            switch self {
            case .quality: "waveform.badge.magnifyingglass"
            case .stems: "square.3.layers.3d"
            case .repair: "wand.and.stars"
            }
        }

        /// Same tool, any stem model.
        func sameTool(as other: Kind) -> Bool {
            switch (self, other) {
            case (.quality, .quality), (.repair, .repair), (.stems, .stems): true
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
    var state: State = .queued
    /// 0…1 while running, when the engine reports it.
    var progress: Double?
    var resultURL: URL?
    /// The engine's own status line while running (Apollo: "Loading model", …).
    var statusText: String?
    let createdAt: Date

    init(trackID: Track.ID, trackName: String, kind: Kind, id: UUID = UUID(), createdAt: Date = Date()) {
        self.id = id
        self.trackID = trackID
        self.trackName = trackName
        self.kind = kind
        self.createdAt = createdAt
    }

    /// The row's status line: "Queued", "Separating · 42%", "Done", the error.
    var statusLine: String {
        switch state {
        case .queued: return "Waiting"
        case .running:
            let verb = switch kind {
            case .quality: "Checking"
            case .stems: "Separating"
            case .repair: "Repairing"
            }
            let label = statusText ?? verb
            return progress.map { "\(label) · \(DJFormat.percent($0))" } ?? "\(label)…"
        case .finished: return "Done"
        case .failed(let message): return message
        case .cancelled: return "Cancelled"
        }
    }
}
