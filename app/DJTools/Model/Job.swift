import AudioExport
import Foundation

/// One run of a tool on one track. Quality checks and Track ID are cheap and
/// run side by side; a Process run that only normalizes decodes the file and
/// runs two at a time; one that repairs or separates stems is heavy and runs
/// one at a time. A Process run also tracks its steps, for the stepper.
struct Job: Identifiable, Equatable, Sendable {
    enum Kind: Equatable, Sendable {
        case quality
        /// Track ID: Shazam + Apple Music. Light, network-bound.
        case identify
        /// Measure only (the Normalize row's readout).
        case loudness
        /// Repair → normalize to the target → stems, saved once.
        case process(ProcessRecipe, DJLoudnessTarget)

        var isHeavy: Bool {
            if case .process(let recipe, _) = self { return recipe.isHeavy }
            return false
        }

        var isProcess: Bool {
            if case .process = self { return true }
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

        /// A check or measurement (no file type).
        var isBackground: Bool { self == .quality || self == .identify || self == .loudness }

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

        var isUnsuccessful: Bool {
            switch self {
            case .failed, .cancelled: true
            default: false
            }
        }
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
    /// A Process run's steps, settled when it starts (Repair's suggestion
    /// needs the quality check); empty before that.
    var steps: [ProcessStep] = []
    /// The step running now, and how far along it is (0…1).
    var currentStep: ProcessStep?
    var stepProgress: Double?
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

    /// The steps this run does: settled ones once it started, else the
    /// recipe's plan.
    var plannedSteps: [ProcessStep] {
        guard steps.isEmpty, case .process(let recipe, _) = kind else { return steps }
        return recipe.plannedSteps
    }

    /// Where `step` stands in this run.
    func stage(of step: ProcessStep) -> StepStage {
        let planned = plannedSteps
        guard let index = planned.firstIndex(of: step) else { return .skipped }
        if state == .finished { return .done }
        guard state == .running, let current = currentStep, let at = planned.firstIndex(of: current) else { return .waiting }
        return index < at ? .done : index == at ? .running : .waiting
    }

    /// "Repairing · 42%" for the running step.
    var stepLine: String {
        let label = statusText ?? currentStep?.verb ?? "Starting"
        return stepProgress.map { "\(label) · \(DJFormat.percent($0))" } ?? "\(label)…"
    }
}

/// A step's place in a Process run, for the stepper.
enum StepStage: Equatable, Sendable {
    case waiting, running, done, skipped
}
