# Engines: the seam to the packages

The app never imports QualityKit, StemsKit or ApolloBridge directly. It talks to
three protocols in `EngineProtocols.swift`, using its own copies of the contract
types in `EngineTypes.swift` (`DJQualityReport`, `DJStemModel`, … — same fields
and cases as `docs/CONTRACTS.md`, prefixed `DJ` so nothing clashes once the
packages are linked). Today only the fakes in `FakeEngines.swift` conform.

| Protocol | Package API it mirrors |
| --- | --- |
| `QualityChecking.analyze(_:)` | `QualityAnalyzer.analyze(_:)` |
| `StemSeparating.separate(input:model:outputDirectory:progress:)` | `StemSeparator(model:).separate(input:outputDirectory:progress:)` |
| `ApolloRepairing.state/install/repair/cancel` | `ApolloRuntime` (same names) |
| `ApolloRepairing.reset()` | not in the package: delete `<supportDirectory>/runtime/` |

## Wiring the real engines

1. **project.yml** — add the local packages and link them to the `DJTools` target:

   ```yaml
   packages:
     QualityKit:   { path: ../Packages/QualityKit }
     StemsKit:     { path: ../Packages/StemsKit }
     ApolloBridge: { path: ../Packages/ApolloBridge }
   # targets.DJTools.dependencies:
     - package: QualityKit
     - package: StemsKit
     - package: ApolloBridge
   ```

   Bundle `apollo/` as a folder resource (`- path: ../apollo` with
   `type: folder` and `buildPhase: resources`; exclude `.venv`), so
   `Bundle.main.url(forResource: "apollo", withExtension: nil)` finds it.

2. **Adapters** — add `Engines/RealEngines.swift` with three thin types:

   - `QualityKitAdapter: QualityChecking` — call `QualityAnalyzer.analyze(url)`
     and copy each field into `DJQualityReport`; map the verdict with
     `DJQualityVerdict(rawValue: report.verdict.rawValue) ?? .unknown`.
   - `StemsKitAdapter: StemSeparating` — an `actor` keeping one `StemSeparator`
     per `DJStemModel` (`StemModel(rawValue: model.rawValue)!`, the raw values
     match); return `DJStemResult(stems: result.stems)`. Cancellation is the
     calling task's.
   - `ApolloBridgeAdapter: ApolloRepairing` — wraps one `ApolloRuntime(projectDirectory:supportDirectory:)`,
     maps `ApolloSetupState` case for case, forwards `install`/`repair`/`cancel`,
     and implements `reset()` by removing `supportDirectory/runtime`.

3. **`Engines.real(supportDirectory:)`** in `EngineProtocols.swift` — return
   `Engines(quality:stems:apollo:isFake: false)` built from the adapters
   instead of `nil`. `supportDirectory` is `AppPaths.support`
   (`~/Library/Application Support/DJTools`).

That's all: once `real` returns non-nil the app uses it, unless launched with
`-useFakeEngines` (the Xcode scheme passes it for Run; untick it there to try the
real engines from Xcode). `-useFakeEngines NO` insists on the real ones.

## Fakes

`-useFakeEngines` (or no real engines linked) picks them; the toolbar then shows
"Demo engines". Quality verdicts are deterministic per file name (a name with
"128" reads Low quality, "fake" Fake lossless). Stems and repairs count up for a
few seconds and write one-second silent WAVs where the real ones would write
output. The fake Apollo "install" leaves a marker in
`App Support/DJTools/fake-engines/`, never in `runtime/`. `-fakeEngineSpeed 4`
runs them four times faster.

## Previews

`DJTools -renderPreviews <dir>` (Debug) renders the main screens with fixture
data to PNGs and exits, no window or GUI session needed — see
`Debug/PreviewRenderer.swift`.
