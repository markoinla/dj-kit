# Engines: the seam to the packages

The app talks to the packages only through three protocols in
`EngineProtocols.swift`, using its own copies of the contract types in
`EngineTypes.swift` (`DJQualityReport`, `DJStemModel`, … — same fields and
cases as `docs/CONTRACTS.md`, prefixed `DJ` so nothing clashes). Only
`RealEngines.swift` imports QualityKit, StemsKit and ApolloBridge.

| Protocol | Adapter (`RealEngines.swift`) | Package API |
| --- | --- | --- |
| `QualityChecking` | `QualityKitAdapter` | `QualityAnalyzer.analyze(_:)` |
| `StemSeparating` | `StemsKitAdapter` (actor, one `StemSeparator` per model, kept alive) | `StemSeparator(model:modelsDirectory:).separate(...)` |
| `ApolloRepairing` | `ApolloBridgeAdapter` | `ApolloRuntime` (`repair` with `status:`) |
| `ApolloRepairing.reset()` | deletes `<supportDirectory>/runtime/` | — |

Adapters deliver every progress/status callback on the main queue, in order
(`MainHop`). Task cancellation of a repair also cancels the Apollo subprocess.

`Engines.real(supportDirectory:)` builds them; `supportDirectory` is
`AppPaths.support` (`~/Library/Application Support/DJTools`, or
`-supportDirectory <path>`). Apollo's project is the bundled
`Contents/Resources/apollo/`, copied by the "Bundle apollo/" build phase in
`project.yml` (pyproject.toml, uv.lock, .python-version, src/, LICENSE,
NOTICE.md — never tests/, .venv or caches). The app is not sandboxed: Apollo
spawns uv and Python from App Support.

Heavy jobs (stems and Apollo repairs, ~6 GB peak each) share one slot in
`AppModel` (`heavyInFlight`), so they never run together.

## Building

```sh
cd app && xcodegen
xcodebuild -project DJTools.xcodeproj -scheme DJTools -configuration Release \
  -destination platform=macOS,arch=arm64 -derivedDataPath .dd \
  CODE_SIGNING_ALLOWED=NO ARCHS=arm64 ONLY_ACTIVE_ARCH=YES build
```

`ARCHS=arm64 ONLY_ACTIVE_ARCH=YES` on the command line matters for Release:
without it the package targets build universal, and demucs-mlx-swift doesn't
compile for x86_64 (no `Float16`). The app bundle then holds
`Resources/apollo/` and `Resources/mlx-swift_Cmlx.bundle` (default.metallib).

## Headless self-test

```sh
DJTools.app/Contents/MacOS/DJTools -selfTest <audio> <out dir> \
  -supportDirectory <scratch dir> [-selfTestApollo] [-selfTestSkipStems] [-useFakeEngines]
```

Runs quality check, htdemucs stems and (with `-selfTestApollo`) Apollo
install + repair through the same adapters the window uses, one after the
other, prints one JSON object (timings, outputs, callback counts and whether
any arrived off the main thread) and exits 0/1. Works in Release, no GUI
session needed; `-supportDirectory` keeps models and the Apollo runtime out of
`~/Library`. See `Debug/SelfTest.swift`.

## Fakes

`-useFakeEngines` picks them (the Xcode scheme passes it for Run; untick it
there to try the real engines), as does a build missing `Resources/apollo/`;
`-useFakeEngines NO` insists on the real ones. The toolbar then shows
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
