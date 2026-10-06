import ApolloBridge
import Foundation
import QualityKit
import StemsKit

// The real engines: thin adapters from the packages' APIs to the app's
// protocols (Engines/README.md). They copy values field for field, keep the
// heavy objects alive, and deliver every progress/status callback on the main
// queue, in order, so the UI never sees updates from a background executor.

/// Runs `body` on the main actor, FIFO with earlier hops (a `Task` per update
/// could reorder them and make a progress bar step backwards).
enum MainHop {
    static func wrap<T: Sendable>(_ callback: @escaping @Sendable (T) -> Void) -> @Sendable (T) -> Void {
        { value in DispatchQueue.main.async { callback(value) } }
    }
}

/// `QualityKit.QualityAnalyzer`.
struct QualityKitAdapter: QualityChecking {
    func analyze(_ url: URL) async throws -> DJQualityReport {
        let r = try await QualityAnalyzer.analyze(url)
        return DJQualityReport(
            url: r.url, container: r.container, isLosslessContainer: r.isLosslessContainer,
            declaredBitrateKbps: r.declaredBitrateKbps, sampleRate: r.sampleRate, channels: r.channels,
            duration: r.duration, cutoffHz: r.cutoffHz,
            verdict: DJQualityVerdict(rawValue: r.verdict.rawValue) ?? .unknown,
            summary: r.summary
        )
    }
}

/// `StemsKit.StemSeparator`, one per model, kept for the app's lifetime so
/// the loaded weights and compiled graphs are reused between tracks.
actor StemsKitAdapter: StemSeparating {
    private let modelsDirectory: URL
    private var separators: [DJStemModel: StemSeparator] = [:]

    /// Weights go in `<supportDirectory>/models/` (docs/CONTRACTS.md).
    init(supportDirectory: URL) {
        modelsDirectory = supportDirectory.appending(path: "models", directoryHint: .isDirectory)
    }

    private func separator(for model: DJStemModel) -> StemSeparator {
        if let existing = separators[model] { return existing }
        // Same raw values on both sides (htdemucs, htdemucsFT, htdemucs6s).
        let created = StemSeparator(model: StemModel(rawValue: model.rawValue)!, modelsDirectory: modelsDirectory)
        separators[model] = created
        return created
    }

    nonisolated func separate(
        input: URL, model: DJStemModel, outputDirectory: URL,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> DJStemResult {
        let separator = await separator(for: model)
        let result = try await separator.separate(
            input: input, outputDirectory: outputDirectory, progress: MainHop.wrap(progress)
        )
        return DJStemResult(stems: result.stems)
    }
}

/// `ApolloBridge.ApolloRuntime`. `reset()` deletes `<supportDirectory>/runtime/`.
struct ApolloBridgeAdapter: ApolloRepairing {
    let runtime: ApolloRuntime
    let supportDirectory: URL

    init(projectDirectory: URL, supportDirectory: URL) {
        runtime = ApolloRuntime(projectDirectory: projectDirectory, supportDirectory: supportDirectory)
        self.supportDirectory = supportDirectory
    }

    func state() async -> DJApolloSetupState {
        switch await runtime.state() {
        case .notInstalled: .notInstalled
        case .installing(let line): .installing(line)
        case .ready: .ready
        case .failed(let message): .failed(message)
        }
    }

    func install(progress: @escaping @Sendable (String) -> Void) async throws {
        try await runtime.install(progress: MainHop.wrap(progress))
    }

    func repair(
        input: URL, output: URL,
        progress: @escaping @Sendable (Double) -> Void,
        status: @escaping @Sendable (String) -> Void
    ) async throws -> URL {
        try await withTaskCancellationHandler {
            try await runtime.repair(
                input: input, output: output,
                progress: MainHop.wrap(progress), status: MainHop.wrap(status)
            )
        } onCancel: {
            // The runtime waits on a subprocess; cancelling the task alone wouldn't stop it.
            Task { await runtime.cancel() }
        }
    }

    func cancel() async {
        await runtime.cancel()
    }

    func reset() async throws {
        await runtime.cancel()
        let runtimeDirectory = supportDirectory.appending(path: "runtime", directoryHint: .isDirectory)
        if FileManager.default.fileExists(atPath: runtimeDirectory.path) {
            try FileManager.default.removeItem(at: runtimeDirectory)
        }
    }
}
