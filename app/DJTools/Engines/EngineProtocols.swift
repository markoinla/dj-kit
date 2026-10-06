import Foundation

// The seam between the app and the engine packages. Each protocol's methods
// have the same shape as the package API in docs/CONTRACTS.md; the app only
// ever talks to these. Real adapters (one small file per package) and the
// fakes in FakeEngines.swift both conform. See Engines/README.md.

/// `QualityKit.QualityAnalyzer.analyze(_:)`.
protocol QualityChecking: Sendable {
    func analyze(_ url: URL) async throws -> DJQualityReport
}

/// `StemsKit.StemSeparator.separate(input:outputDirectory:progress:)`, with
/// the model passed per call (the package takes it in `init`; the adapter
/// keeps one `StemSeparator` per model).
///
/// Writes `<outputDirectory>/<track name> (Stems)/<stem>.wav`. Cancelled by
/// cancelling the calling task.
protocol StemSeparating: Sendable {
    func separate(
        input: URL, model: DJStemModel, outputDirectory: URL,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> DJStemResult
}

/// Apollo repair (`ApolloMLX.ApolloMLXRepairer` behind `ApolloMLXAdapter`),
/// plus `reset()` for Settings ▸ Remove Apollo Model.
protocol ApolloRepairing: Sendable {
    func state() async -> DJApolloSetupState
    /// One-time setup (the model weights). `progress` gets status lines for the UI.
    func install(progress: @escaping @Sendable (String) -> Void) async throws
    /// `status` gets status lines ("Loading model", "Repairing", "Writing
    /// output") for the queue row.
    func repair(
        input: URL, output: URL,
        progress: @escaping @Sendable (Double) -> Void,
        status: @escaping @Sendable (String) -> Void
    ) async throws -> URL
    func cancel() async
    /// Removes what setup downloaded so the next repair sets it up again.
    func reset() async throws
}

/// `LoudnessKit`: `LoudnessAnalyzer.measure(_:progress:)` and
/// `Normalizer.gain(for:targetLUFS:ceilingDBTP:)`. Measuring decodes the
/// whole file (about half a second for a 4-minute track), so it isn't part
/// of the automatic quality check. Cancelled by cancelling the calling task.
protocol LoudnessMeasuring: Sendable {
    func measure(_ url: URL, progress: @escaping @Sendable (Double) -> Void) async throws -> DJLoudnessReport
    func plan(for report: DJLoudnessReport, target: DJLoudnessTarget) -> DJNormalizationPlan
}

/// The engines the app runs on.
struct Engines: Sendable {
    var quality: any QualityChecking
    var stems: any StemSeparating
    var apollo: any ApolloRepairing
    var loudness: any LoudnessMeasuring
    var identifier: any TrackIdentifying
    /// True for the fakes: the toolbar says "Demo engines".
    var isFake: Bool

    /// The real engines: QualityKit, StemsKit, ApolloMLX and LoudnessKit behind their
    /// adapters (Engines/RealEngines.swift), and Track ID (Engines/TrackIdentifier.swift).
    static func real(supportDirectory: URL) -> Engines {
        Engines(
            quality: QualityKitAdapter(),
            stems: StemsKitAdapter(supportDirectory: supportDirectory),
            apollo: ApolloMLXAdapter(supportDirectory: supportDirectory),
            loudness: LoudnessKitAdapter(),
            identifier: ShazamTrackIdentifier(),
            isFake: false
        )
    }

    static func fake(supportDirectory: URL, speed: Double = 1) -> Engines {
        Engines(
            quality: FakeQualityChecker(speed: speed),
            stems: FakeStemSeparator(speed: speed),
            apollo: FakeApolloRuntime(supportDirectory: supportDirectory, speed: speed),
            loudness: FakeLoudnessMeter(speed: speed),
            identifier: FakeTrackIdentifier(speed: speed),
            isFake: true
        )
    }

    /// `-useFakeEngines` (or `-useFakeEngines YES`) forces the fakes;
    /// `-useFakeEngines NO` (or no argument) uses the real ones.
    static func forLaunch(supportDirectory: URL, arguments: [String] = CommandLine.arguments) -> Engines {
        if LaunchArguments.flag("useFakeEngines", in: arguments) != true {
            return real(supportDirectory: supportDirectory)
        }
        let speed = LaunchArguments.value("fakeEngineSpeed", in: arguments).flatMap(Double.init) ?? 1
        return fake(supportDirectory: supportDirectory, speed: speed)
    }
}

/// `-name`, `-name YES|NO` and `-name value` launch arguments.
enum LaunchArguments {
    /// nil when absent; true for a bare `-name` or a truthy value.
    static func flag(_ name: String, in arguments: [String] = CommandLine.arguments) -> Bool? {
        guard let index = arguments.firstIndex(of: "-\(name)") else { return nil }
        let next = arguments.indices.contains(index + 1) ? arguments[index + 1] : nil
        guard let next, !next.hasPrefix("-") else { return true }
        return ["yes", "true", "1"].contains(next.lowercased())
    }

    static func value(_ name: String, in arguments: [String] = CommandLine.arguments) -> String? {
        guard let index = arguments.firstIndex(of: "-\(name)"), arguments.indices.contains(index + 1) else { return nil }
        return arguments[index + 1]
    }
}

/// Track ID: Shazam + Apple Music (`ShazamTrackIdentifier`). Returns nil when
/// nothing matched; throws when no listen got an answer at all (offline,
/// ShazamKit not allowed for this build). Cancelled by cancelling the task.
protocol TrackIdentifying: Sendable {
    func identify(_ url: URL, progress: @escaping @Sendable (Double) -> Void) async throws -> DJTrackIdentity?
}
