import ApolloMLX
import Foundation
import os
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

/// `ApolloMLX.ApolloMLXRepairer`: the native MLX port of Apollo, no Python.
///
/// Setup is `prepare()` (download the pinned 66 MB checkpoint from Hugging
/// Face, SHA-check it and convert it to `apollo-mlx.safetensors` in Swift);
/// "installed" is the converted weights being there. Repairs run at fp16.
/// The package reports only progress, so the status lines are made up here:
/// "Loading model" until the first chunk, "Repairing", then "Writing output".
/// `reset()` deletes the weights.
actor ApolloMLXAdapter: ApolloRepairing {
    private let repairer: ApolloMLXRepairer
    private var installLine: String?
    private var current: Task<URL, any Error>?

    /// Weights go in `<supportDirectory>/models/apollo-mlx/`.
    init(supportDirectory: URL) {
        repairer = ApolloMLXRepairer(
            modelsDirectory: supportDirectory.appending(path: "models/apollo-mlx", directoryHint: .isDirectory)
        )
    }

    func state() async -> DJApolloSetupState {
        if let installLine { return .installing(installLine) }
        return await repairer.isPrepared ? .ready : .notInstalled
    }

    func install(progress: @escaping @Sendable (String) -> Void) async throws {
        installLine = "Starting…"
        defer { installLine = nil }
        let onMain = MainHop.wrap(progress)
        try await repairer.prepare { [weak self] line in
            Task { await self?.setInstallLine(line) }
            onMain(line)
        }
    }

    private func setInstallLine(_ line: String) {
        if installLine != nil { installLine = line }
    }

    func repair(
        input: URL, output: URL,
        progress: @escaping @Sendable (Double) -> Void,
        status: @escaping @Sendable (String) -> Void
    ) async throws -> URL {
        let onProgress = MainHop.wrap(progress), onStatus = MainHop.wrap(status)
        let phase = OSAllocatedUnfairLock(initialState: 0)  // 0 loading, 1 repairing, 2 writing
        let repairer = self.repairer
        onStatus("Loading model")
        let task = Task {
            try await repairer.repair(input: input, output: output) { fraction in
                let next = fraction >= 1 ? 2 : 1
                let changed = phase.withLock { current in
                    guard next > current else { return false }
                    current = next
                    return true
                }
                if changed { onStatus(next == 2 ? "Writing output" : "Repairing") }
                onProgress(fraction)
            }
        }
        current?.cancel()
        current = task
        defer { if current == task { current = nil } }
        return try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
    }

    func cancel() async {
        current?.cancel()
        current = nil
    }

    func reset() async throws {
        await cancel()
        try await repairer.removeWeights()
    }
}
