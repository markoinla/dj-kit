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

/// `ApolloBridge.ApolloRuntime`, plus `reset()` for Settings ▸ Reset Apollo
/// Runtime (not in the package: the adapter deletes
/// `<supportDirectory>/runtime/`, which is where the contract keeps uv,
/// Python and the venv).
protocol ApolloRepairing: Sendable {
    func state() async -> DJApolloSetupState
    /// uv + Python + deps + weights. `progress` gets status lines for the UI.
    func install(progress: @escaping @Sendable (String) -> Void) async throws
    /// `status` gets Apollo's own status lines ("Loading model",
    /// "Repairing on MPS", …) for the queue row.
    func repair(
        input: URL, output: URL,
        progress: @escaping @Sendable (Double) -> Void,
        status: @escaping @Sendable (String) -> Void
    ) async throws -> URL
    func cancel() async
    /// Removes the installed runtime so the next repair sets it up again.
    func reset() async throws
}

/// The three engines the app runs on.
struct Engines: Sendable {
    var quality: any QualityChecking
    var stems: any StemSeparating
    var apollo: any ApolloRepairing
    /// True for the fakes: the toolbar says "Demo engines".
    var isFake: Bool

    /// The real engines: QualityKit, StemsKit and ApolloBridge behind their
    /// adapters (Engines/RealEngines.swift). Apollo runs the `apollo/` uv
    /// project bundled in Resources; nil only if that is missing from the
    /// bundle (a broken build), so the app falls back to the fakes.
    static func real(supportDirectory: URL) -> Engines? {
        guard let apolloProject = Bundle.main.url(forResource: "apollo", withExtension: nil) else {
            NSLog("DJTools: apollo/ isn't in the app bundle; using the demo engines")
            return nil
        }
        return Engines(
            quality: QualityKitAdapter(),
            stems: StemsKitAdapter(supportDirectory: supportDirectory),
            apollo: ApolloBridgeAdapter(projectDirectory: apolloProject, supportDirectory: supportDirectory),
            isFake: false
        )
    }

    static func fake(supportDirectory: URL, speed: Double = 1) -> Engines {
        Engines(
            quality: FakeQualityChecker(speed: speed),
            stems: FakeStemSeparator(speed: speed),
            apollo: FakeApolloRuntime(supportDirectory: supportDirectory, speed: speed),
            isFake: true
        )
    }

    /// `-useFakeEngines` (or `-useFakeEngines YES`) forces the fakes;
    /// `-useFakeEngines NO` insists on the real ones. Without the argument
    /// the real engines are used when linked, the fakes otherwise.
    static func forLaunch(supportDirectory: URL, arguments: [String] = CommandLine.arguments) -> Engines {
        let wantsFakes = LaunchArguments.flag("useFakeEngines", in: arguments)
        if wantsFakes != true, let real = real(supportDirectory: supportDirectory) {
            return real
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
